# frozen_string_literal: true

require "json"
require "minitest/autorun"

require_relative "../scripts/assert_bottle_matrix"

class AssertBottleMatrixTest < Minitest::Test
  SOURCE_SHA = "1" * 40
  AUTHORIZATION_SHA = "2" * 40
  MANIFEST_SHA256 = "3" * 64
  FORMULA_SHA256 = "4" * 64
  OCI_DIGESTS = {
    "macos-arm64" => "5" * 64,
    "linux-x86_64" => "6" * 64,
    "linux-arm64" => "7" * 64
  }.freeze

  TARGETS = {
    "macos-arm64" => {
      "runner" => "macos-15",
      "os" => "macos",
      "architecture" => "arm64",
      "bottleTag" => "arm64_sequoia"
    },
    "linux-x86_64" => {
      "runner" => "ubuntu-24.04",
      "os" => "linux",
      "architecture" => "x86_64",
      "bottleTag" => "x86_64_linux"
    },
    "linux-arm64" => {
      "runner" => "ubuntu-24.04-arm",
      "os" => "linux",
      "architecture" => "arm64",
      "bottleTag" => "arm64_linux"
    }
  }.freeze

  def test_accepts_only_the_complete_exact_three_target_matrix
    result = CliDistribution::BottleMatrix.assert!(entries, expected: expected)

    assert_equal "crewcli.homebrew-bottle-matrix/v1", result.fetch("schema")
    assert_equal TARGETS.keys.sort, result.fetch("bottles").map { |item| item.fetch("target") }.sort
    assert_equal "0.1.0", result.fetch("version")
    assert_equal SOURCE_SHA, result.fetch("sourceSha")
    assert_equal AUTHORIZATION_SHA, result.fetch("authorizationSha")
    assert_equal MANIFEST_SHA256, result.fetch("manifestSha256")
    assert_equal FORMULA_SHA256, result.fetch("formulaSha256")
  end

  def test_rejects_missing_duplicate_or_unknown_targets
    invalid = [
      entries.drop(1),
      [*entries, entries.first],
      [*entries.drop(1), evidence("windows-wsl2", target: "windows-wsl2")]
    ]

    invalid.each do |value|
      assert_raises(CliDistribution::BottleMatrixError) do
        CliDistribution::BottleMatrix.assert!(value, expected: expected)
      end
    end
  end

  def test_rejects_runner_architecture_tag_and_filename_drift
    invalid = [
      replace("macos-arm64", "runner", "macos-14"),
      replace("linux-x86_64", "architecture", "arm64"),
      replace("linux-arm64", "bottleTag", "x86_64_linux"),
      replace_bottle("macos-arm64", "fileName", "crewent--0.1.0.wrong.bottle.tar.gz")
    ]

    invalid.each do |value|
      assert_raises(CliDistribution::BottleMatrixError) do
        CliDistribution::BottleMatrix.assert!(value, expected: expected)
      end
    end
  end

  def test_rejects_identity_digest_status_and_mutable_registry_drift
    invalid = [
      replace("macos-arm64", "status", "FAIL"),
      replace("macos-arm64", "version", "0.1.1"),
      replace("macos-arm64", "sourceSha", "a" * 40),
      replace("macos-arm64", "authorizationSha", "a" * 40),
      replace("macos-arm64", "manifestSha256", "a" * 64),
      replace("macos-arm64", "formulaSha256", "a" * 64),
      replace_bottle("macos-arm64", "sha256", "A" * 64),
      replace_bottle(
        "macos-arm64",
        "blobUrl",
        "https://ghcr.io/v2/zoe-llc/homebrew-crewcli/crewent/manifests/latest"
      )
    ]

    invalid.each do |value|
      assert_raises(CliDistribution::BottleMatrixError) do
        CliDistribution::BottleMatrix.assert!(value, expected: expected)
      end
    end
  end

  def test_rejects_unknown_fields_and_sensitive_or_local_values
    invalid = [
      entries.tap { |value| value[0] = value[0].merge("token" => "secret-sentinel") },
      replace_bottle("macos-arm64", "fileName", "/tmp/crewent.bottle.tar.gz"),
      replace_bottle(
        "macos-arm64",
        "blobUrl",
        "https://token@ghcr.io/v2/zoe-llc/homebrew-crewcli/crewent/blobs/sha256:#{"5" * 64}"
      )
    ]

    invalid.each do |value|
      error = assert_raises(CliDistribution::BottleMatrixError) do
        CliDistribution::BottleMatrix.assert!(value, expected: expected)
      end
      refute_match(/secret-sentinel/, error.message)
    end
  end

  private

  def expected
    {
      "version" => "0.1.0",
      "sourceSha" => SOURCE_SHA,
      "authorizationSha" => AUTHORIZATION_SHA,
      "manifestSha256" => MANIFEST_SHA256,
      "formulaSha256" => FORMULA_SHA256
    }
  end

  def entries
    TARGETS.map { |target, values| evidence(target, values) }
  end

  def evidence(target, values = {})
    target_values = TARGETS.fetch(target, {}).merge(values)
    digest = OCI_DIGESTS.fetch(target, "8" * 64)
    {
      "schema" => "crewcli.homebrew-bottle-evidence/v1",
      "target" => target_values.fetch("target", target),
      "status" => "PASS",
      "version" => "0.1.0",
      "sourceSha" => SOURCE_SHA,
      "authorizationSha" => AUTHORIZATION_SHA,
      "manifestSha256" => MANIFEST_SHA256,
      "formulaSha256" => FORMULA_SHA256,
      "runner" => target_values.fetch("runner", "ubuntu-24.04"),
      "os" => target_values.fetch("os", "linux"),
      "architecture" => target_values.fetch("architecture", "x86_64"),
      "bottle" => {
        "tag" => target_values.fetch("bottleTag", "x86_64_linux"),
        "fileName" => "crewent--0.1.0.#{target_values.fetch("bottleTag", "x86_64_linux")}.bottle.tar.gz",
        "sha256" => digest,
        "blobUrl" => "https://ghcr.io/v2/zoe-llc/homebrew-crewcli/crewent/blobs/sha256:#{digest}"
      }
    }
  end

  def replace(target, key, value)
    entries.map do |item|
      item.fetch("target") == target ? item.merge(key => value) : item
    end
  end

  def replace_bottle(target, key, value)
    entries.map do |item|
      next item unless item.fetch("target") == target

      item.merge("bottle" => item.fetch("bottle").merge(key => value))
    end
  end
end
