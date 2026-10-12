# frozen_string_literal: true

require_relative "manifest"

module CliDistribution
  module ReleaseAsset
    module_function

    MANIFEST_NAME = "distribution-release.json"

    def manifest_asset_url(value, config:, version:)
      configuration = Configuration.parse(config)
      Contract.object(value, "release")
      Contract.pattern(version, Contract::SEMVER, "version")
      Contract.fail_at("version", "must not be a placeholder") if version == "0.0.0"

      tag = "cli-v#{version}"
      Contract.equal(value["tag_name"], tag, "release.tag_name")
      Contract.equal(value["immutable"], true, "release.immutable")
      Contract.equal(value["draft"], false, "release.draft")
      Contract.equal(value["prerelease"], false, "release.prerelease")

      assets = value["assets"]
      Contract.fail_at("release.assets", "must be an array") unless assets.is_a?(Array)
      manifests = assets.select do |asset|
        asset.is_a?(Hash) && asset["name"] == MANIFEST_NAME
      end
      Contract.fail_at("release.assets", "must contain one exact manifest") unless manifests.length == 1

      asset = manifests.first
      id = asset["id"]
      unless id.is_a?(Integer) && id.positive?
        Contract.fail_at("release.assets.manifest.id", "must be a positive integer")
      end
      Contract.equal(asset["state"], "uploaded", "release.assets.manifest.state")

      repository = configuration.source_repository
      api_url = "https://api.github.com/repos/#{repository}/releases/assets/#{id}"
      download_url = "https://github.com/#{repository}/releases/download/#{tag}/#{MANIFEST_NAME}"
      Contract.equal(asset["url"], api_url, "release.assets.manifest.url")
      Contract.safe_https(
        asset["url"],
        "api.github.com",
        %r{\A/repos/#{Regexp.escape(repository)}/releases/assets/#{id}\z},
        "release.assets.manifest.url"
      )
      Contract.equal(
        asset["browser_download_url"],
        download_url,
        "release.assets.manifest.browser_download_url"
      )
      Contract.safe_https(
        asset["browser_download_url"],
        "github.com",
        %r{\A/#{Regexp.escape(repository)}/releases/download/#{Regexp.escape(tag)}/#{MANIFEST_NAME}\z},
        "release.assets.manifest.browser_download_url"
      )
      api_url
    end
  end
end
