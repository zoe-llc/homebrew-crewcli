#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "securerandom"

module CliDistribution
  class GhcrReadbackError < TypeError; end

  module GhcrReadback
    module_function

    OCI_REPOSITORY = "ghcr.io/zoe-llc/crewcli/crewent"
    PACKAGE_NAME = "crewcli/crewent"
    TAP_REPOSITORY = "zoe-llc/homebrew-crewcli"
    ANONYMOUS_PULL_KEYS = %w[
      schema repository version tagReference digestReference result
    ].freeze
    SHA256 = /\A[a-f0-9]{64}\z/.freeze
    COMMIT = /\A[a-f0-9]{40}\z/.freeze
    SEMVER = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/.freeze
    IDENTITY = /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/.freeze
    SENSITIVE = /secret-sentinel|bearer\s|cookie=|_authtoken|-----BEGIN .*PRIVATE KEY-----/i

    def assert!(package:, graphql:, tags:, manifests:, matrix:, readbacks:, consumer_user:, anonymous_pull:)
      equal(package.fetch("name"), PACKAGE_NAME, "package.name")
      equal(package.fetch("package_type"), "container", "package.package_type")
      equal(package.fetch("visibility"), "private", "package.visibility")
      equal(package.dig("owner", "login"), "zoe-llc", "package.owner.login")

      nodes = graphql.dig("data", "organization", "packages", "nodes")
      fail_at("graphql.packages", "must contain the exact linked package") unless nodes.is_a?(Array)
      linked = nodes.select do |node|
        node.is_a?(Hash) && node["name"] == PACKAGE_NAME && node["packageType"] == "DOCKER"
      end
      fail_at("graphql.packages", "must contain the exact linked package once") unless linked.length == 1
      equal(linked.first.dig("repository", "nameWithOwner"), TAP_REPOSITORY, "graphql.package.repository")

      observed_tags = tags.fetch("tags")
      unless observed_tags.is_a?(Array) && observed_tags.all? { |tag| safe_tag?(tag) } && observed_tags.uniq.length == observed_tags.length
        fail_at("tags", "must be a unique safe tag list")
      end

      bottles = matrix.fetch("bottles")
      fail_at("matrix.bottles", "must contain exactly three bottles") unless bottles.is_a?(Array) && bottles.length == 3
      version = pattern(matrix.fetch("version"), SEMVER, "matrix.version")
      fail_at("matrix.version", "must not be a placeholder") if version == "0.0.0"
      source_sha = pattern(matrix.fetch("sourceSha"), COMMIT, "matrix.sourceSha")
      authorization_sha = pattern(matrix.fetch("authorizationSha"), COMMIT, "matrix.authorizationSha")
      version_manifest = manifests.fetch("tag:#{version}") do
        fail_at("manifests", "does not contain the exact version tag")
      end
      version_digest = pattern(
        version_manifest.fetch("digest"),
        /\Asha256:[a-f0-9]{64}\z/,
        "manifests.#{version}.digest"
      )
      validate_anonymous_pull!(
        anonymous_pull,
        version: version,
        digest_reference: "#{OCI_REPOSITORY}@#{version_digest}"
      )
      evidence = bottles.map.with_index do |entry, index|
        fail_at("matrix.bottles[#{index}]", "must be an object") unless entry.is_a?(Hash)
        target = safe_string(entry.fetch("target"), "matrix.bottles[#{index}].target")
        bottle = entry.fetch("bottle")
        fail_at("matrix.bottles[#{index}].bottle", "must be an object") unless bottle.is_a?(Hash)
        bottle_tag = safe_string(bottle.fetch("tag"), "matrix.bottles[#{index}].bottle.tag")
        digest = pattern(bottle.fetch("sha256"), SHA256, "matrix.bottles[#{index}].bottle.sha256")
        equal(
          bottle.fetch("blobUrl"),
          "https://ghcr.io/v2/zoe-llc/crewcli/crewent/blobs/sha256:#{digest}",
          "matrix.bottles[#{index}].bottle.blobUrl"
        )
        matches = observed_tags.each_with_object([]) do |manifest_tag, values|
          index_manifest = manifests.fetch("tag:#{manifest_tag}") { fail_at("manifests", "does not contain tag #{manifest_tag}") }
          index_digest = pattern(index_manifest.fetch("digest"), /\Asha256:[a-f0-9]{64}\z/, "manifests.#{manifest_tag}.digest")
          equal(index_manifest.fetch("reference"), "#{OCI_REPOSITORY}@#{index_digest}", "manifests.#{manifest_tag}.reference")
          descriptors = index_manifest.dig("content", "manifests")
          fail_at("manifests.#{manifest_tag}", "must be an OCI image index") unless descriptors.is_a?(Array)
          descriptors.each do |descriptor|
            child_digest = pattern(descriptor.fetch("digest"), /\Asha256:[a-f0-9]{64}\z/, "manifests.#{manifest_tag}.child.digest")
            manifest = manifests.fetch(child_digest) { fail_at("manifests", "does not contain child #{child_digest}") }
            equal(manifest.fetch("digest"), child_digest, "manifests.child.digest")
            equal(manifest.fetch("reference"), "#{OCI_REPOSITORY}@#{child_digest}", "manifests.child.reference")
            layer_digests = manifest.dig("content", "layers")
            next unless layer_digests.is_a?(Array) && layer_digests.any? { |layer| layer.is_a?(Hash) && layer["digest"] == "sha256:#{digest}" }

            values << [manifest_tag, manifest]
          end
        end
        fail_at("manifests", "must reference the exact bottle blob") if matches.empty?
        manifest_tag, manifest = matches.sort_by { |entry| [entry.first, entry.last.fetch("digest", "")] }.first
        manifest_digest = pattern(manifest.fetch("digest"), /\Asha256:[a-f0-9]{64}\z/, "manifests.#{manifest_tag}.digest")
        equal(manifest.fetch("reference"), "#{OCI_REPOSITORY}@#{manifest_digest}", "manifests.#{manifest_tag}.reference")
        readback_path = readbacks.fetch(digest) { fail_at("readbacks", "does not contain #{digest}") }
        equal(Digest::SHA256.file(regular_file(readback_path, "readback")).hexdigest, digest, "readback.sha256")
        {
          "target" => target,
          "bottleTag" => bottle_tag,
          "manifestTag" => manifest_tag,
          "sha256" => digest,
          "blobUrl" => bottle.fetch("blobUrl"),
          "manifestRef" => manifest.fetch("reference")
        }
      end
      targets = evidence.map { |entry| entry.fetch("target") }
      fail_at("matrix.bottles.target", "must be unique") unless targets.uniq.length == targets.length

      consumer = pattern(consumer_user, IDENTITY, "consumer.user")
      {
        "schema" => "crewcli.ghcr-readback/v1",
        "version" => version,
        "sourceSha" => source_sha,
        "authorizationSha" => authorization_sha,
        "package" => {
          "name" => PACKAGE_NAME,
          "visibility" => "private",
          "repository" => TAP_REPOSITORY
        },
        "anonymousPullRejected" => true,
        "consumer" => {
          "user" => consumer,
          "credential" => "classic-pat-read-packages",
          "readVerified" => true
        },
        "bottles" => evidence.sort_by { |entry| entry.fetch("target") }
      }
    rescue KeyError
      fail_at("ghcr readback", "contains missing fields")
    end

    def safe_tag?(value)
      value.is_a?(String) && /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/.match?(value) && !SENSITIVE.match?(value)
    end

    def validate_anonymous_pull!(value, version:, digest_reference:)
      exact_keys(value, ANONYMOUS_PULL_KEYS, "anonymousPull")
      equal(value.fetch("schema"), "crewcli.ghcr-anonymous-pull/v1", "anonymousPull.schema")
      equal(value.fetch("repository"), OCI_REPOSITORY, "anonymousPull.repository")
      equal(value.fetch("version"), version, "anonymousPull.version")
      equal(
        value.fetch("tagReference"),
        "#{OCI_REPOSITORY}:#{version}",
        "anonymousPull.tagReference"
      )
      equal(value.fetch("digestReference"), digest_reference, "anonymousPull.digestReference")
      equal(value.fetch("result"), "REJECTED", "anonymousPull.result")
    end

    def exact_keys(value, keys, path)
      fail_at(path, "must be an object") unless value.is_a?(Hash)
      missing = keys.reject { |key| value.key?(key) }
      extra = value.keys.reject { |key| keys.include?(key) }
      fail_at(path, "contains missing or unknown fields") unless missing.empty? && extra.empty?
    end

    def safe_string(value, path)
      fail_at(path, "must be a string") unless value.is_a?(String)
      fail_at(path, "contains prohibited sensitive data") if SENSITIVE.match?(value)
      value
    end

    def pattern(value, expression, path)
      safe_string(value, path)
      fail_at(path, "has an invalid format") unless expression.match?(value)
      value
    end

    def equal(value, expected, path)
      safe_string(value, path) if value.is_a?(String)
      fail_at(path, "does not match the contract") unless value == expected
      value
    end

    def regular_file(path, label)
      candidate = Pathname.new(path).expand_path
      state = candidate.lstat
      fail_at(label, "must be a regular non-symlink file") unless state.file? && !state.symlink?
      candidate
    rescue Errno::ENOENT
      fail_at(label, "must be a regular non-symlink file")
    end

    def regular_directory(path, label)
      candidate = Pathname.new(path).expand_path
      state = candidate.lstat
      fail_at(label, "must be a real directory") unless state.directory? && !state.symlink?
      candidate
    rescue Errno::ENOENT
      fail_at(label, "must be a real directory")
    end

    def read_json(path, label)
      JSON.parse(regular_file(path, label).read)
    rescue JSON::ParserError
      fail_at(label, "must contain valid JSON")
    end

    def write_atomic(path, value)
      destination = Pathname.new(path).expand_path
      fail_at("output", "already exists") if destination.exist? || destination.symlink?
      destination.dirname.mkpath
      temporary = destination.dirname/".#{destination.basename}.#{Process.pid}.#{SecureRandom.hex(8)}.tmp"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write("#{JSON.generate(value)}\n")
        file.flush
        file.fsync
      end
      File.rename(temporary, destination)
      File.open(destination.dirname, File::RDONLY, &:fsync)
    ensure
      temporary&.delete if temporary&.exist?
    end

    def fail_at(path, reason)
      raise GhcrReadbackError, "#{path}: #{reason}"
    end

    def run(argv)
      allowed = %w[
        --package --graphql --tags --manifests --matrix --readbacks
        --consumer-user --anonymous-pull --output
      ]
      fail_at("arguments", "must be option/value pairs") unless argv.length == allowed.length * 2
      values = {}
      argv.each_slice(2) do |option, value|
        fail_at("arguments", "contains an unknown or duplicate option") unless allowed.include?(option) && !values.key?(option)
        values[option] = value
      end
      fail_at("arguments", "is incomplete") unless values.keys.sort == allowed.sort

      matrix = read_json(values.fetch("--matrix"), "matrix")
      manifests_directory = regular_directory(values.fetch("--manifests"), "manifests")
      readbacks_directory = regular_directory(values.fetch("--readbacks"), "readbacks")
      tags = read_json(values.fetch("--tags"), "tags")
      manifests = tags.fetch("tags").each_with_object({}) do |tag, documents|
        fail_at("manifest tag", "has an invalid format") unless safe_tag?(tag)
        index = read_json(manifests_directory/"tag-#{tag}.json", "manifest index")
        documents["tag:#{tag}"] = index
        descriptors = index.dig("content", "manifests")
        fail_at("manifest index", "must contain manifests") unless descriptors.is_a?(Array)
        descriptors.each do |descriptor|
          digest = pattern(descriptor.fetch("digest"), /\Asha256:[a-f0-9]{64}\z/, "manifest child digest")
          documents[digest] ||= read_json(manifests_directory/"#{digest.delete_prefix("sha256:")}.json", "manifest child")
        end
      end
      readbacks = matrix.fetch("bottles").to_h do |entry|
        digest = entry.fetch("bottle").fetch("sha256")
        [digest, readbacks_directory/"#{digest}.tar.gz"]
      end
      result = assert!(
        package: read_json(values.fetch("--package"), "package"),
        graphql: read_json(values.fetch("--graphql"), "graphql"),
        tags: tags,
        manifests: manifests,
        matrix: matrix,
        readbacks: readbacks,
        consumer_user: values.fetch("--consumer-user"),
        anonymous_pull: read_json(values.fetch("--anonymous-pull"), "anonymous pull")
      )
      write_atomic(values.fetch("--output"), result)
      result
    rescue KeyError
      fail_at("ghcr readback", "contains missing fields")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    CliDistribution::GhcrReadback.run(ARGV)
  rescue CliDistribution::GhcrReadbackError => e
    warn "assert-ghcr-readback: #{e.message}"
    exit 1
  end
end
