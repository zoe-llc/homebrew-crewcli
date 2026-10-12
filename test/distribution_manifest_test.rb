# frozen_string_literal: true

require "json"
require "minitest/autorun"

require_relative "../lib/cli_distribution/manifest"

class DistributionManifestTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures", __dir__)
  CURRENT_CONFIG = {
    "schema" => "crewcli.homebrew-distribution/v1",
    "releaseId" => "phase2-cli",
    "sourceRepository" => "zoe-llc/crewcli",
    "formulaName" => "crewent",
    "tap" => "zoe-llc/crewcli",
    "bottleRoot" => "https://ghcr.io/v2/zoe-llc/crewcli"
  }.freeze
  ALTERNATE_CONFIG = CURRENT_CONFIG.merge(
    "sourceRepository" => "zoe-llc/sample-cli",
    "formulaName" => "sample-cli",
    "tap" => "zoe-llc/sample-cli",
    "bottleRoot" => "https://ghcr.io/v2/zoe-llc/sample-cli"
  ).freeze

  def test_parses_closed_provider_neutral_manifest
    manifest = parse_fixture("crewcli.distribution-release.v1.json", CURRENT_CONFIG)

    assert_equal "phase2-cli", manifest.release_id
    assert_equal "0.1.0", manifest.version
    assert_equal "@crewent/cli", manifest.package_name
    assert_equal ["crewent", "crewcli"], manifest.commands
    assert_equal ">=22", manifest.node_requirement
  end

  def test_accepts_alternate_distribution_names_without_changing_release_identity
    manifest = parse_fixture("alternate-name.distribution-release.v1.json", ALTERNATE_CONFIG)

    assert_equal "phase2-cli", manifest.release_id
    assert_equal "@sample/cli", manifest.package_name
    assert_equal ["sample-cli", "sample"], manifest.commands
  end

  def test_rejects_unknown_fields_credentials_and_homebrew_metadata
    base = fixture("crewcli.distribution-release.v1.json")
    invalid_values = [
      base.merge("token" => "secret-sentinel"),
      mutate(base, "source") { |value| value.merge("credential" => "secret-sentinel") },
      mutate(base, "artifact") { |value| value.merge("bottle" => "arm64") },
      mutate(base, "runtime") { |value| value.merge("formula" => "crewcli") },
      mutate(base, "package") { |value| value.merge("tap" => "zoe-llc/crewcli") }
    ]

    invalid_values.each do |value|
      error = assert_raises(CliDistribution::ContractError) do
        CliDistribution::Manifest.parse(value, config: CURRENT_CONFIG)
      end
      refute_match(/secret-sentinel/, error.message)
    end
  end

  def test_rejects_identity_url_digest_and_command_drift
    base = fixture("crewcli.distribution-release.v1.json")
    invalid_values = [
      mutate(base, "version") { "0.0.0" },
      mutate(base, "source") { |value| value.merge("repository" => "other/repo") },
      mutate(base, "source") { |value| value.merge("commit" => "ABC") },
      mutate(base, "artifact") { |value| value.merge("sha256" => "A" * 64) },
      mutate(base, "artifact") { |value| value.merge("url" => "https://token@github.com/zoe-llc/crewcli/releases/download/cli-v0.1.0/crewcli-cli-0.1.0.tgz") },
      mutate(base, "artifact") { |value| value.merge("url" => "#{value.fetch("url")}?token=secret") },
      mutate(base, "runtime") do |value|
        value.merge("commands" => { "primary" => "crewcli", "aliases" => ["crewcli"] })
      end
    ]

    invalid_values.each do |value|
      assert_raises(CliDistribution::ContractError) do
        CliDistribution::Manifest.parse(value, config: CURRENT_CONFIG)
      end
    end
  end

  def test_rejects_unknown_or_unsafe_adapter_configuration
    invalid_values = [
      CURRENT_CONFIG.merge("unknown" => true),
      CURRENT_CONFIG.merge("releaseId" => "crewcli"),
      CURRENT_CONFIG.merge("formulaName" => "../crewcli"),
      CURRENT_CONFIG.merge("tap" => "crewcli"),
      CURRENT_CONFIG.merge("bottleRoot" => "https://ghcr.io/v2/zoe-llc/homebrew-crewcli"),
      CURRENT_CONFIG.merge("bottleRoot" => "https://token@ghcr.io/v2/zoe-llc/crewcli"),
      CURRENT_CONFIG.merge("bottleRoot" => "https://ghcr.io/v2/zoe-llc/crewcli?token=secret")
    ]

    invalid_values.each do |value|
      assert_raises(CliDistribution::ContractError) do
        CliDistribution::Configuration.parse(value)
      end
    end
  end

  private

  def parse_fixture(name, config)
    CliDistribution::Manifest.parse(fixture(name), config: config)
  end

  def fixture(name)
    JSON.parse(File.read(File.join(FIXTURES, name)))
  end

  def mutate(value, key)
    copy = JSON.parse(JSON.generate(value))
    copy[key] = yield(copy.fetch(key))
    copy
  end
end
