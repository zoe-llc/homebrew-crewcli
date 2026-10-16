# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "../scripts/assert_ghcr_readback"

class AssertGhcrReadbackTest < Minitest::Test
  REPOSITORY = "ghcr.io/zoe-llc/crewcli/crewent"
  PACKAGE_NAME = "crewcli/crewent"

  def test_accepts_private_linked_package_manifests_and_consumer_readbacks
    with_inputs do |inputs|
      result = CliDistribution::GhcrReadback.assert!(**inputs, consumer_user: "employee-reader")

      assert_equal "crewcli.ghcr-readback/v1", result.fetch("schema")
      assert_equal "0.1.0", result.fetch("version")
      assert_equal "1" * 40, result.fetch("sourceSha")
      assert_equal "2" * 40, result.fetch("authorizationSha")
      assert_equal "private", result.dig("package", "visibility")
      assert_equal "zoe-llc/homebrew-crewcli", result.dig("package", "repository")
      assert_equal true, result.fetch("anonymousPullRejected")
      assert_equal true, result.dig("consumer", "readVerified")
      assert_equal 3, result.fetch("bottles").length
      result.fetch("bottles").each do |bottle|
        assert_match(%r{\A#{Regexp.escape(REPOSITORY)}@sha256:[a-f0-9]{64}\z}, bottle.fetch("manifestRef"))
      end
    end
  end

  def test_rejects_non_private_or_unlinked_packages
    with_inputs do |inputs|
      inputs.fetch(:package)["visibility"] = "public"
      assert_raises(CliDistribution::GhcrReadbackError) do
        CliDistribution::GhcrReadback.assert!(**inputs, consumer_user: "employee-reader")
      end
    end

    with_inputs do |inputs|
      inputs.dig(:graphql, "data", "organization", "packages", "nodes").first["repository"] = nil
      assert_raises(CliDistribution::GhcrReadbackError) do
        CliDistribution::GhcrReadback.assert!(**inputs, consumer_user: "employee-reader")
      end
    end
  end

  def test_rejects_missing_manifest_or_consumer_blob
    with_inputs do |inputs|
      inputs.fetch(:manifests).delete(inputs.fetch(:manifests).keys.first)
      assert_raises(CliDistribution::GhcrReadbackError) do
        CliDistribution::GhcrReadback.assert!(**inputs, consumer_user: "employee-reader")
      end
    end

    with_inputs do |inputs|
      File.binwrite(inputs.fetch(:readbacks).fetch(inputs.fetch(:readbacks).keys.first), "tampered")
      assert_raises(CliDistribution::GhcrReadbackError) do
        CliDistribution::GhcrReadback.assert!(**inputs, consumer_user: "employee-reader")
      end
    end
  end

  def test_rejects_false_missing_or_unknown_anonymous_pull_evidence
    with_inputs do |inputs|
      inputs.fetch(:anonymous_pull)["result"] = false
      assert_raises(CliDistribution::GhcrReadbackError) do
        CliDistribution::GhcrReadback.assert!(**inputs, consumer_user: "employee-reader")
      end
    end

    with_inputs do |inputs|
      inputs.fetch(:anonymous_pull).delete("result")
      assert_raises(CliDistribution::GhcrReadbackError) do
        CliDistribution::GhcrReadback.assert!(**inputs, consumer_user: "employee-reader")
      end
    end

    with_inputs do |inputs|
      inputs.fetch(:anonymous_pull)["result"] = "ALLOWED"
      assert_raises(CliDistribution::GhcrReadbackError) do
        CliDistribution::GhcrReadback.assert!(**inputs, consumer_user: "employee-reader")
      end
    end

    with_inputs do |inputs|
      inputs.fetch(:anonymous_pull)["unexpected"] = true
      assert_raises(CliDistribution::GhcrReadbackError) do
        CliDistribution::GhcrReadback.assert!(**inputs, consumer_user: "employee-reader")
      end
    end
  end

  def test_cli_requires_and_consumes_the_anonymous_pull_record
    with_inputs do |inputs, directory|
      package_path = write_json(directory, "package.json", inputs.fetch(:package))
      graphql_path = write_json(directory, "graphql.json", inputs.fetch(:graphql))
      tags_path = write_json(directory, "tags.json", inputs.fetch(:tags))
      matrix_path = write_json(directory, "matrix.json", inputs.fetch(:matrix))
      anonymous_path = write_json(directory, "anonymous.json", inputs.fetch(:anonymous_pull))
      manifests_directory = File.join(directory, "manifests")
      readbacks_directory = File.join(directory, "readbacks")
      FileUtils.mkdir_p(manifests_directory)
      FileUtils.mkdir_p(readbacks_directory)
      inputs.fetch(:manifests).each do |key, value|
        name = if key.start_with?("tag:")
                 "tag-#{key.delete_prefix("tag:")}.json"
               else
                 "#{key.delete_prefix("sha256:")}.json"
               end
        write_json(manifests_directory, name, value)
      end
      inputs.fetch(:readbacks).each do |digest, path|
        FileUtils.cp(path, File.join(readbacks_directory, "#{digest}.tar.gz"))
      end
      output_path = File.join(directory, "output.json")

      result = CliDistribution::GhcrReadback.run([
        "--package", package_path,
        "--graphql", graphql_path,
        "--tags", tags_path,
        "--manifests", manifests_directory,
        "--matrix", matrix_path,
        "--readbacks", readbacks_directory,
        "--consumer-user", "employee-reader",
        "--anonymous-pull", anonymous_path,
        "--output", output_path
      ])

      assert_equal true, result.fetch("anonymousPullRejected")
      assert_equal true, JSON.parse(File.read(output_path)).fetch("anonymousPullRejected")
      assert_raises(CliDistribution::GhcrReadbackError) do
        CliDistribution::GhcrReadback.run([
          "--package", package_path,
          "--graphql", graphql_path,
          "--tags", tags_path,
          "--manifests", manifests_directory,
          "--matrix", matrix_path,
          "--readbacks", readbacks_directory,
          "--consumer-user", "employee-reader",
          "--output", File.join(directory, "missing-anonymous.json")
        ])
      end
    end
  end

  private

  def with_inputs
    Dir.mktmpdir("ghcr-readback-") do |directory|
      bottles = %w[macos-arm64 linux-x86_64 linux-arm64].map.with_index do |target, index|
        bytes = "#{target} bottle bytes"
        digest = Digest::SHA256.hexdigest(bytes)
        path = File.join(directory, "#{digest}.tar.gz")
        File.binwrite(path, bytes)
        [
          {
            "target" => target,
            "bottle" => {
              "tag" => %w[arm64_sequoia x86_64_linux arm64_linux].fetch(index),
              "fileName" => "crewent--0.1.0.#{target}.bottle.tar.gz",
              "sha256" => digest,
              "blobUrl" => "https://ghcr.io/v2/zoe-llc/crewcli/crewent/blobs/sha256:#{digest}"
            }
          },
          path
        ]
      end
      matrix = {
        "schema" => "crewcli.homebrew-bottle-matrix/v1",
        "version" => "0.1.0",
        "sourceSha" => "1" * 40,
        "authorizationSha" => "2" * 40,
        "manifestSha256" => "3" * 64,
        "formulaSha256" => "4" * 64,
        "bottles" => bottles.map(&:first)
      }
      child_manifests = bottles.each_with_index.to_h do |(entry, _path), index|
        digest = entry.dig("bottle", "sha256")
        manifest_digest = Digest::SHA256.hexdigest("manifest #{digest}")
        [
          "sha256:#{manifest_digest}",
          {
            "reference" => "#{REPOSITORY}@sha256:#{manifest_digest}",
            "digest" => "sha256:#{manifest_digest}",
            "content" => { "layers" => [{ "digest" => "sha256:#{digest}" }] }
          }
        ]
      end
      index_digest = Digest::SHA256.hexdigest("index")
      manifests = child_manifests.merge(
        "tag:0.1.0" => {
          "reference" => "#{REPOSITORY}@sha256:#{index_digest}",
          "digest" => "sha256:#{index_digest}",
          "content" => {
            "manifests" => child_manifests.keys.map { |digest| { "digest" => digest } }
          }
        }
      )
      inputs = {
        package: {
          "name" => PACKAGE_NAME,
          "package_type" => "container",
          "visibility" => "private",
          "owner" => { "login" => "zoe-llc" }
        },
        graphql: {
          "data" => {
            "organization" => {
              "packages" => {
                "nodes" => [{
                  "name" => PACKAGE_NAME,
                  "packageType" => "DOCKER",
                  "repository" => { "nameWithOwner" => "zoe-llc/homebrew-crewcli" }
                }]
              }
            }
          }
        },
        tags: { "tags" => ["0.1.0"] },
        manifests: manifests,
        matrix: matrix,
        readbacks: bottles.to_h { |entry, path| [entry.dig("bottle", "sha256"), path] },
        anonymous_pull: {
          "schema" => "crewcli.ghcr-anonymous-pull/v1",
          "repository" => REPOSITORY,
          "version" => "0.1.0",
          "tagReference" => "#{REPOSITORY}:0.1.0",
          "digestReference" => "#{REPOSITORY}@sha256:#{index_digest}",
          "result" => "REJECTED"
        }
      }
      yield(inputs, directory)
    end
  end

  def write_json(directory, name, value)
    path = File.join(directory, name)
    File.write(path, "#{JSON.generate(value)}\n")
    path
  end
end
