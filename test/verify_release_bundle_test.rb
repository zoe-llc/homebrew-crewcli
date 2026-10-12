# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "../scripts/verify_release_bundle"

class VerifyReleaseBundleTest < Minitest::Test
  CONFIG = {
    "schema" => "crewcli.homebrew-distribution/v1",
    "releaseId" => "phase2-cli",
    "sourceRepository" => "zoe-llc/crewcli",
    "formulaName" => "crewent",
    "tap" => "zoe-llc/crewcli",
    "bottleRoot" => "https://ghcr.io/v2/zoe-llc/homebrew-crewcli"
  }.freeze
  VERSION = "0.1.0"
  SOURCE_SHA = "1" * 40
  AUTHORIZATION_SHA = "2" * 40

  def test_verifies_the_complete_immutable_release_and_all_payload_digests
    with_bundle do |release, directory|
      result = CliDistribution::ReleaseBundle.verify!(
        release: release,
        directory: directory,
        config: CONFIG,
        expected: expected
      )

      assert_equal VERSION, result.fetch("version")
      assert_equal SOURCE_SHA, result.fetch("sourceSha")
      assert_equal AUTHORIZATION_SHA, result.fetch("authorizationSha")
      assert_equal "crewent-cli-0.1.0.tgz", result.fetch("artifactFileName")
      assert_match(/\A[a-f0-9]{64}\z/, result.fetch("manifestSha256"))
    end
  end

  def test_rejects_mutable_or_incomplete_release_and_identity_drift
    with_bundle do |release, directory|
      invalid = [
        release.merge("immutable" => false),
        release.merge("draft" => true),
        release.merge("tag_name" => "cli-v0.1.1"),
        release.merge("assets" => release.fetch("assets").drop(1))
      ]
      invalid.each do |value|
        assert_raises(CliDistribution::ReleaseBundleError) do
          CliDistribution::ReleaseBundle.verify!(
            release: value,
            directory: directory,
            config: CONFIG,
            expected: expected
          )
        end
      end

      drift = expected.merge("authorizationSha" => "3" * 40)
      assert_raises(CliDistribution::ReleaseBundleError) do
        CliDistribution::ReleaseBundle.verify!(
          release: release,
          directory: directory,
          config: CONFIG,
          expected: drift
        )
      end
    end
  end

  def test_rejects_payload_digest_manifest_and_unknown_field_drift
    with_bundle do |release, directory|
      File.binwrite(File.join(directory, "sbom.cdx.json"), "changed")
      assert_raises(CliDistribution::ReleaseBundleError) do
        CliDistribution::ReleaseBundle.verify!(
          release: release,
          directory: directory,
          config: CONFIG,
          expected: expected
        )
      end
    end

    with_bundle do |release, directory|
      evidence_path = File.join(directory, "release-evidence.json")
      evidence = JSON.parse(File.read(evidence_path)).merge("token" => "secret-sentinel")
      File.write(evidence_path, JSON.generate(evidence))
      error = assert_raises(CliDistribution::ReleaseBundleError) do
        CliDistribution::ReleaseBundle.verify!(
          release: release,
          directory: directory,
          config: CONFIG,
          expected: expected
        )
      end
      refute_match(/secret-sentinel/, error.message)
    end

    with_bundle do |release, directory|
      manifest_path = File.join(directory, "distribution-release.json")
      manifest = JSON.parse(File.read(manifest_path)).merge("token" => "secret-sentinel")
      bytes = "#{JSON.generate(manifest)}\n"
      File.write(manifest_path, bytes)
      evidence_path = File.join(directory, "release-evidence.json")
      evidence = JSON.parse(File.read(evidence_path))
      evidence.fetch("subjects").find do |subject|
        subject.fetch("role") == "distribution-manifest"
      end["sha256"] = Digest::SHA256.hexdigest(bytes)
      File.write(evidence_path, "#{JSON.generate(evidence)}\n")

      error = assert_raises(CliDistribution::ReleaseBundleError) do
        CliDistribution::ReleaseBundle.verify!(
          release: release,
          directory: directory,
          config: CONFIG,
          expected: expected
        )
      end
      refute_match(/secret-sentinel/, error.message)
    end
  end

  private

  def expected
    {
      "version" => VERSION,
      "sourceSha" => SOURCE_SHA,
      "authorizationSha" => AUTHORIZATION_SHA
    }
  end

  def with_bundle
    Dir.mktmpdir("release-bundle-") do |directory|
      artifact = "exact tarball bytes"
      artifact_sha = Digest::SHA256.hexdigest(artifact)
      manifest = {
        "schema" => "crewcli.distribution-release/v1",
        "releaseId" => "phase2-cli",
        "version" => VERSION,
        "source" => { "repository" => "zoe-llc/crewcli", "commit" => SOURCE_SHA },
        "package" => { "name" => "@crewent/cli" },
        "artifact" => {
          "type" => "npm-tarball",
          "fileName" => "crewent-cli-0.1.0.tgz",
          "url" => "https://github.com/zoe-llc/crewcli/releases/download/cli-v0.1.0/crewent-cli-0.1.0.tgz",
          "sha256" => artifact_sha
        },
        "runtime" => {
          "commands" => { "primary" => "crewent", "aliases" => ["crewcli"] },
          "node" => ">=22"
        }
      }
      payloads = {
        "crewent-cli-0.1.0.tgz" => artifact,
        "package-artifact.json" => "{\"kind\":\"package\"}\n",
        "distribution-release.json" => "#{JSON.generate(manifest)}\n",
        "sbom.cdx.json" => "{\"kind\":\"sbom\"}\n",
        "redistribution-evidence.json" => "{\"kind\":\"redistribution\"}\n"
      }
      payloads.each { |name, bytes| File.binwrite(File.join(directory, name), bytes) }
      roles = %w[
        package-tarball package-metadata distribution-manifest
        cyclonedx-sbom redistribution-evidence
      ]
      evidence = {
        "schema" => "crewcli.release-evidence/v2",
        "releaseId" => "phase2-cli",
        "version" => VERSION,
        "tag" => "cli-v0.1.0",
        "source" => { "repository" => "zoe-llc/crewcli", "commit" => SOURCE_SHA },
        "authorization" => {
          "repository" => "zoe-llc/crewcli",
          "commit" => AUTHORIZATION_SHA,
          "mode" => "repository-record"
        },
        "workflow" => { "repository" => "zoe-llc/crewcli", "runId" => "123", "runAttempt" => 1 },
        "expectedReleaseAssets" => [*payloads.keys, "release-evidence.json"],
        "subjects" => payloads.map.with_index do |(name, bytes), index|
          { "role" => roles.fetch(index), "fileName" => name, "sha256" => Digest::SHA256.hexdigest(bytes) }
        end
      }
      File.write(File.join(directory, "release-evidence.json"), "#{JSON.generate(evidence)}\n")
      assets = evidence.fetch("expectedReleaseAssets").map.with_index do |name, index|
        {
          "id" => 100 + index,
          "name" => name,
          "state" => "uploaded",
          "url" => "https://api.github.com/repos/zoe-llc/crewcli/releases/assets/#{100 + index}",
          "browser_download_url" => "https://github.com/zoe-llc/crewcli/releases/download/cli-v0.1.0/#{name}"
        }
      end
      release = {
        "tag_name" => "cli-v0.1.0",
        "immutable" => true,
        "draft" => false,
        "prerelease" => false,
        "assets" => assets
      }
      yield release, directory
    end
  end
end
