# frozen_string_literal: true

require "minitest/autorun"

require_relative "../lib/cli_distribution/release_asset"

class ReleaseAssetTest < Minitest::Test
  CONFIG = {
    "schema" => "crewcli.homebrew-distribution/v1",
    "releaseId" => "phase2-cli",
    "sourceRepository" => "zoe-llc/crewcli",
    "formulaName" => "crewent",
    "tap" => "zoe-llc/crewcli",
    "bottleRoot" => "https://ghcr.io/v2/zoe-llc/crewcli"
  }.freeze

  def test_selects_the_exact_manifest_asset_from_an_immutable_release
    assert_equal(
      "https://api.github.com/repos/zoe-llc/crewcli/releases/assets/123",
      CliDistribution::ReleaseAsset.manifest_asset_url(
        release,
        config: CONFIG,
        version: "0.1.0"
      )
    )
  end

  def test_rejects_mutable_draft_prerelease_or_wrong_tag_releases
    invalid = [
      release.merge("immutable" => false),
      release.merge("draft" => true),
      release.merge("prerelease" => true),
      release.merge("tag_name" => "cli-v0.1.1")
    ]

    invalid.each do |value|
      assert_raises(CliDistribution::ContractError) do
        CliDistribution::ReleaseAsset.manifest_asset_url(value, config: CONFIG, version: "0.1.0")
      end
    end
  end

  def test_rejects_invalid_version_missing_duplicate_or_wrong_manifest_asset
    manifest = release.fetch("assets").first
    invalid = [
      release.merge("assets" => []),
      release.merge("assets" => [manifest, manifest.merge("id" => 124)]),
      release.merge("assets" => [manifest.merge("state" => "new")]),
      release.merge("assets" => [manifest.merge("url" => "https://api.github.com/repos/zoe-llc/other/releases/assets/123")]),
      release.merge("assets" => [manifest.merge("browser_download_url" => "https://token@github.com/zoe-llc/crewcli/releases/download/cli-v0.1.0/distribution-release.json")])
    ]

    invalid.each do |value|
      assert_raises(CliDistribution::ContractError) do
        CliDistribution::ReleaseAsset.manifest_asset_url(value, config: CONFIG, version: "0.1.0")
      end
    end
    assert_raises(CliDistribution::ContractError) do
      CliDistribution::ReleaseAsset.manifest_asset_url(release, config: CONFIG, version: "../0.1.0")
    end
  end

  private

  def release
    {
      "tag_name" => "cli-v0.1.0",
      "immutable" => true,
      "draft" => false,
      "prerelease" => false,
      "assets" => [
        {
          "id" => 123,
          "name" => "distribution-release.json",
          "state" => "uploaded",
          "url" => "https://api.github.com/repos/zoe-llc/crewcli/releases/assets/123",
          "browser_download_url" => "https://github.com/zoe-llc/crewcli/releases/download/cli-v0.1.0/distribution-release.json"
        },
        {
          "id" => 124,
          "name" => "release-evidence.json",
          "state" => "uploaded",
          "url" => "https://api.github.com/repos/zoe-llc/crewcli/releases/assets/124",
          "browser_download_url" => "https://github.com/zoe-llc/crewcli/releases/download/cli-v0.1.0/release-evidence.json"
        }
      ]
    }
  end
end
