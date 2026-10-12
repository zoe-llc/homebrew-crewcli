# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/assert_canary_matrix"

class AssertCanaryMatrixTest < Minitest::Test
  NOW = Time.utc(2026, 10, 12, 12, 0, 0)
  TARGETS = %w[macos-arm64 linux-x86_64 linux-arm64].freeze

  def setup
    @expected = {
      "schema" => "crewcli.homebrew-distribution-canary-expected/v1",
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
      "bottleRunId" => "123456",
      "bottleRunAttempt" => 1,
      "bottleWorkflowSha" => "a" * 40,
      "workflowRepository" => "zoe-llc/homebrew-crewcli",
      "workflowRunId" => "234567",
      "workflowRunAttempt" => 2,
      "workflowSha" => "b" * 40
    }
  end

  def test_builds_closed_distribution_target_from_lifecycle_only
    result = build_target("macos-arm64")

    assert_equal "crewcli.homebrew-distribution-canary-evidence/v1", result.fetch("schema")
    assert_equal "PASS", result.fetch("status")
    assert_equal "macos-arm64", result.fetch("target")
    assert_equal "macos-15", result.dig("platform", "label")
    assert_equal true, result.fetch("installation").values.all?
    assert_equal true, result.fetch("commands").values.all?
    assert_equal true, result.fetch("lifecycle").values.all?
    assert_equal @expected.fetch("bottles"), result.dig("identity", "bottles")
    assert_equal "123456", result.dig("producer", "runId")
    assert_equal "234567", result.dig("workflow", "runId")
    refute result.key?("runtime")
    refute result.key?("evidence")
    refute_includes JSON.generate(result), "productSlug"
    refute_includes JSON.generate(result), "changeIntentNumber"
  end

  def test_rejects_product_fields_and_sensitive_values
    product = lifecycle("linux-arm64")
    product["productSlug"] = "cli-distribution-canary"
    assert_target_rejected(product)

    wsl = lifecycle("linux-arm64")
    wsl["platform"]["wsl2"] = true
    assert_target_rejected(wsl)

    sensitive = lifecycle("linux-arm64")
    sensitive["diagnostic"] = "https://reader:secret-sentinel@example.invalid"
    assert_target_rejected(sensitive)

    expected = deep_copy(@expected)
    expected["hostOrigin"] = "https://crewent.app"
    assert_raises(CliDistribution::CanaryMatrixError) do
      CliDistribution::CanaryMatrix.build_target(
        target: "linux-arm64", expected: expected, lifecycle: lifecycle("linux-arm64"), now: NOW
      )
    end
  end

  def test_rejects_failed_or_mismatched_lifecycle_evidence
    failed = lifecycle("linux-x86_64")
    failed["lifecycle"]["reinstallPassed"] = false
    assert_target_rejected(failed, target: "linux-x86_64")

    wrong_platform = lifecycle("linux-x86_64")
    wrong_platform["platform"]["architecture"] = "arm64"
    assert_target_rejected(wrong_platform, target: "linux-x86_64")

    source_fallback = lifecycle("linux-x86_64")
    source_fallback["installation"]["bottleOnly"] = false
    assert_target_rejected(source_fallback, target: "linux-x86_64")
  end

  def test_aggregates_exactly_three_fresh_targets
    result = CliDistribution::CanaryMatrix.assert_matrix!(
      TARGETS.map { |target| build_target(target) }, expected: @expected, now: NOW
    )

    assert_equal "crewcli.homebrew-distribution-canary-matrix/v1", result.fetch("schema")
    assert_equal TARGETS.sort, result.fetch("targets").map { |entry| entry.fetch("target") }.sort
    assert_equal @expected.fetch("formulaSha256"), result.dig("identity", "formulaSha256")
    assert_equal "123456", result.dig("producer", "runId")
    assert_equal "234567", result.dig("workflow", "runId")
  end

  def test_rejects_missing_duplicate_stale_na_or_identity_drift
    entries = TARGETS.map { |target| build_target(target) }

    assert_matrix_rejected(entries.take(2))
    assert_matrix_rejected([entries[0], entries[1], deep_copy(entries[0])])

    stale = deep_copy(entries)
    stale[0]["timestamp"] = (NOW - 7_201).iso8601(3)
    assert_matrix_rejected(stale)

    na = deep_copy(entries)
    na[0]["status"] = "N/A"
    assert_matrix_rejected(na)

    drift = deep_copy(entries)
    drift[0]["identity"]["formulaSha256"] = "f" * 64
    assert_matrix_rejected(drift)

    producer_drift = deep_copy(entries)
    producer_drift[0]["producer"]["runId"] = "999999"
    assert_matrix_rejected(producer_drift)
  end

  def test_cli_uses_only_distribution_inputs_and_writes_atomically
    Dir.mktmpdir do |directory|
      expected_path = write_json(directory, "expected.json", @expected)
      lifecycle_path = write_json(directory, "lifecycle.json", lifecycle("macos-arm64"))
      target_path = File.join(directory, "target.json")

      CliDistribution::CanaryMatrix.run([
        "target", "--target", "macos-arm64", "--expected", expected_path,
        "--lifecycle", lifecycle_path, "--output", target_path
      ], now: NOW)
      assert File.file?(target_path)
      assert_raises(CliDistribution::CanaryMatrixError) do
        CliDistribution::CanaryMatrix.run([
          "target", "--target", "macos-arm64", "--expected", expected_path,
          "--lifecycle", lifecycle_path, "--output", target_path
        ], now: NOW)
      end

      legacy_path = File.join(directory, "legacy.json")
      assert_raises(CliDistribution::CanaryMatrixError) do
        CliDistribution::CanaryMatrix.run([
          "target", "--target", "macos-arm64", "--expected", expected_path,
          "--phase-ab", lifecycle_path, "--lifecycle", lifecycle_path, "--output", legacy_path
        ], now: NOW)
      end

      target_paths = TARGETS.map do |target|
        write_json(directory, "#{target}.json", build_target(target))
      end
      matrix_path = File.join(directory, "matrix.json")
      CliDistribution::CanaryMatrix.run(
        ["matrix", "--expected", expected_path, "--output", matrix_path, *target_paths], now: NOW
      )
      assert_equal(
        "crewcli.homebrew-distribution-canary-matrix/v1",
        JSON.parse(File.read(matrix_path)).fetch("schema")
      )
    end
  end

  private

  def build_target(target)
    CliDistribution::CanaryMatrix.build_target(
      target: target, expected: @expected, lifecycle: lifecycle(target), now: NOW
    )
  end

  def lifecycle(target)
    platform = CliDistribution::CanaryMatrix::TARGETS.fetch(target)
    {
      "schema" => "crewcli.homebrew-distribution-canary-lifecycle/v1",
      "target" => target,
      "platform" => {
        "os" => platform.fetch("os"),
        "architecture" => platform.fetch("architecture"),
        "host" => platform.fetch("host"),
        "verified" => true
      },
      "installation" => {
        "tapAuthenticated" => true,
        "ghcrAuthenticated" => true,
        "bottleOnly" => true
      },
      "commands" => {
        "primaryVersionMatched" => true,
        "primaryHelpMatched" => true,
        "aliasVersionMatched" => true
      },
      "lifecycle" => {
        "uninstallPassed" => true,
        "reinstallPassed" => true,
        "cleanRollbackPassed" => true
      }
    }
  end

  def assert_target_rejected(value, target: "linux-arm64")
    assert_raises(CliDistribution::CanaryMatrixError) do
      CliDistribution::CanaryMatrix.build_target(
        target: target, expected: @expected, lifecycle: value, now: NOW
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
