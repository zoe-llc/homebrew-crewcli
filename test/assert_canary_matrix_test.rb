# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/assert_canary_matrix"

class AssertCanaryMatrixTest < Minitest::Test
  NOW = Time.utc(2026, 10, 12, 12, 0, 0)
  TARGETS = CliDistribution::CanaryMatrix::TARGETS.keys.freeze

  def setup
    @expected = {
      "schema" => "crewcli.homebrew-canary-expected/v1",
      "version" => "1.2.3",
      "sourceSha" => "1" * 40,
      "authorizationSha" => "2" * 40,
      "artifactSha256" => "3" * 64,
      "manifestSha256" => "4" * 64,
      "formulaSha256" => "5" * 64,
      "bottleMatrixSha256" => "6" * 64,
      "bottles" => {
        "macos-arm64" => "7" * 64,
        "linux-x86_64" => "8" * 64,
        "linux-arm64" => "9" * 64
      },
      "deploySha" => "a" * 40,
      "hostOrigin" => "https://crewent.app",
      "productSlug" => "cli-distribution-canary",
      "changeIntentNumber" => 231,
      "canaryRepository" => "zoe-llc/cli-distribution-canary",
      "canarySha" => "b" * 40,
      "bottleRunId" => "123456",
      "workflowRepository" => "zoe-llc/homebrew-crewcli",
      "workflowRunId" => "234567",
      "workflowRunAttempt" => 1,
      "tapWorkflowSha" => "d" * 40
    }
  end

  def test_builds_one_closed_target_evidence_from_real_ab_c_and_lifecycle_contracts
    phase_ab = phase_evidence("ab")
    phase_c = phase_evidence("c")
    result = CliDistribution::CanaryMatrix.build_target(
      target: "macos-arm64",
      expected: @expected,
      phase_ab: phase_ab,
      phase_c: phase_c,
      lifecycle: lifecycle("macos-arm64"),
      phase_ab_sha256: digest(phase_ab),
      phase_c_sha256: digest(phase_c),
      now: NOW
    )

    assert_equal "crewcli.homebrew-canary-evidence/v1", result.fetch("schema")
    assert_equal "PASS", result.fetch("status")
    assert_equal "macos-arm64", result.fetch("target")
    assert_equal "macos-15", result.dig("runner", "label")
    assert_equal true, result.dig("runner", "verified")
    assert result.fetch("installation").values.all?
    assert result.fetch("runtime").values.all?
    assert result.fetch("lifecycle").values.all?
    assert_equal @expected.fetch("bottles"), result.dig("identity", "bottles")
    refute_includes JSON.generate(result), "session-1"
    refute_includes JSON.generate(result), "/tmp/"
  end

  def test_requires_exact_ab_and_stale_c_identity_and_assertions
    mutations = [
      ->(ab, _) { ab["phase"] = "c" },
      ->(ab, _) { ab["identity"]["manifestSha256"] = "f" * 64 },
      ->(ab, _) { ab["runs"]["b"]["assertions"]["sameSession"] = false },
      ->(_, c) { c["runs"]["c"]["exitCode"] = 0 },
      ->(_, c) { c["runs"]["c"]["assertions"]["staleRejected"] = false },
      ->(_, c) { c["release"]["deploySha"] = "f" * 40 }
    ]

    mutations.each do |mutate|
      ab = phase_evidence("ab")
      c = phase_evidence("c")
      mutate.call(ab, c)
      assert_raises(CliDistribution::CanaryMatrixError) do
        CliDistribution::CanaryMatrix.build_target(
          target: "linux-x86_64",
          expected: @expected,
          phase_ab: ab,
          phase_c: c,
          lifecycle: lifecycle("linux-x86_64"),
          phase_ab_sha256: digest(ab),
          phase_c_sha256: digest(c),
          now: NOW
        )
      end
    end
  end

  def test_rejects_failed_or_sensitive_lifecycle_evidence
    failed = lifecycle("linux-arm64")
    failed["lifecycle"]["upgradePassed"] = false
    assert_target_rejected(failed)

    unverified = lifecycle("linux-arm64")
    unverified["platform"]["hostVerified"] = false
    assert_target_rejected(unverified)

    sensitive = lifecycle("linux-arm64")
    sensitive["target"] = "Bearer secret-sentinel"
    assert_target_rejected(sensitive)
  end

  def test_aggregates_exactly_four_fresh_targets_with_one_identity
    entries = TARGETS.map { |target| target_evidence(target) }
    result = CliDistribution::CanaryMatrix.assert_matrix!(entries, expected: @expected, now: NOW)

    assert_equal "crewcli.homebrew-canary-matrix/v1", result.fetch("schema")
    assert_equal TARGETS.sort, result.fetch("targets").map { |entry| entry.fetch("target") }.sort
    assert_equal @expected.fetch("formulaSha256"), result.dig("identity", "formulaSha256")
  end

  def test_rejects_missing_duplicate_stale_na_or_identity_drift
    entries = TARGETS.map { |target| target_evidence(target) }

    assert_matrix_rejected(entries.take(3))
    assert_matrix_rejected(entries.map.with_index { |entry, index| index == 3 ? deep_copy(entries[0]) : entry })

    stale = deep_copy(entries)
    stale[0]["timestamp"] = (NOW - 7_201).iso8601(3)
    assert_matrix_rejected(stale)

    na = deep_copy(entries)
    na[0]["status"] = "N/A"
    assert_matrix_rejected(na)

    drift = deep_copy(entries)
    drift[0]["identity"]["formulaSha256"] = "f" * 64
    assert_matrix_rejected(drift)
  end

  def test_cli_writes_target_and_matrix_atomically_without_replacing_files
    Dir.mktmpdir do |directory|
      expected_path = write_json(directory, "expected.json", @expected)
      ab = phase_evidence("ab")
      c = phase_evidence("c")
      ab_path = write_json(directory, "ab.json", ab)
      c_path = write_json(directory, "c.json", c)
      lifecycle_path = write_json(directory, "lifecycle.json", lifecycle("macos-arm64"))
      target_path = File.join(directory, "target.json")

      CliDistribution::CanaryMatrix.run([
        "target", "--target", "macos-arm64", "--expected", expected_path,
        "--phase-ab", ab_path, "--phase-c", c_path, "--lifecycle", lifecycle_path,
        "--output", target_path
      ], now: NOW)
      assert File.file?(target_path)
      assert_raises(CliDistribution::CanaryMatrixError) do
        CliDistribution::CanaryMatrix.run([
          "target", "--target", "macos-arm64", "--expected", expected_path,
          "--phase-ab", ab_path, "--phase-c", c_path, "--lifecycle", lifecycle_path,
          "--output", target_path
        ], now: NOW)
      end

      target_paths = TARGETS.map do |target|
        write_json(directory, "#{target}.json", target_evidence(target))
      end
      matrix_path = File.join(directory, "matrix.json")
      CliDistribution::CanaryMatrix.run(
        ["matrix", "--expected", expected_path, "--output", matrix_path, *target_paths],
        now: NOW
      )
      assert_equal "crewcli.homebrew-canary-matrix/v1", JSON.parse(File.read(matrix_path)).fetch("schema")
    end
  end

  private

  def target_evidence(target)
    ab = phase_evidence("ab")
    c = phase_evidence("c")
    CliDistribution::CanaryMatrix.build_target(
      target: target,
      expected: @expected,
      phase_ab: ab,
      phase_c: c,
      lifecycle: lifecycle(target),
      phase_ab_sha256: digest(ab),
      phase_c_sha256: digest(c),
      now: NOW
    )
  end

  def phase_evidence(phase)
    runs = if phase == "ab"
             {
               "a" => phase_run(0, "identityMatched", "treeUnchanged", "contextVerified"),
               "b" => phase_run(0, "identityMatched", "treeUnchanged", "sameSession", "sameContext")
             }
           else
             {
               "c" => phase_run(
                 3, "identityMatched", "treeUnchanged", "staleRejected", "sessionUnchanged", "contextUnchanged"
               )
             }
           end
    {
      "schema" => "crewcli.distribution-canary-evidence/v1",
      "timestamp" => (NOW - 60).iso8601(3),
      "identity" => {
        "cliVersion" => @expected.fetch("version"),
        "packageSha256" => @expected.fetch("artifactSha256"),
        "manifestSha256" => @expected.fetch("manifestSha256"),
        "hostOrigin" => @expected.fetch("hostOrigin"),
        "repository" => @expected.fetch("canaryRepository"),
        "productSlug" => @expected.fetch("productSlug"),
        "changeIntentNumber" => @expected.fetch("changeIntentNumber")
      },
      "release" => {
        "workflowSha" => @expected.fetch("sourceSha"),
        "deploySha" => @expected.fetch("deploySha")
      },
      "phase" => phase,
      "runs" => runs
    }
  end

  def phase_run(exit_code, *assertions)
    {
      "exitCode" => exit_code,
      "sessionId" => "session-1",
      "publishedRevisionId" => "revision-7",
      "contextHash" => "sha256:#{"c" * 64}",
      "assertions" => assertions.to_h { |name| [name, true] }
    }
  end

  def lifecycle(target)
    platform = CliDistribution::CanaryMatrix::TARGETS.fetch(target)
    {
      "schema" => "crewcli.homebrew-canary-lifecycle/v1",
      "target" => target,
      "platform" => {
        "os" => platform.fetch("os"),
        "architecture" => platform.fetch("architecture"),
        "host" => platform.fetch("host"),
        "hostVerified" => true
      },
      "installation" => {
        "tapAuthenticated" => true,
        "ghcrAuthenticated" => true,
        "bottleOnly" => true,
        "versionMatched" => true,
        "helpMatched" => true,
        "aliasMatched" => true
      },
      "lifecycle" => {
        "upgradePassed" => true,
        "uninstallPassed" => true,
        "reinstallPassed" => true,
        "initialRollbackClean" => true
      }
    }
  end

  def digest(value)
    Digest::SHA256.hexdigest("#{JSON.generate(value)}\n")
  end

  def assert_target_rejected(value)
    ab = phase_evidence("ab")
    c = phase_evidence("c")
    assert_raises(CliDistribution::CanaryMatrixError) do
      CliDistribution::CanaryMatrix.build_target(
        target: "linux-arm64", expected: @expected, phase_ab: ab, phase_c: c,
        lifecycle: value, phase_ab_sha256: digest(ab), phase_c_sha256: digest(c), now: NOW
      )
    end
  end

  def assert_matrix_rejected(entries)
    assert_raises(CliDistribution::CanaryMatrixError) do
      CliDistribution::CanaryMatrix.assert_matrix!(entries, expected: @expected, now: NOW)
    end
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def write_json(directory, name, value)
    path = File.join(directory, name)
    File.write(path, "#{JSON.generate(value)}\n")
    path
  end
end
