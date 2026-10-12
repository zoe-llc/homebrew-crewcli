#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "securerandom"

require_relative "../lib/cli_distribution/manifest"

module CliDistribution
  class ReleaseBundleError < TypeError; end

  module ReleaseBundle
    module_function

    EVIDENCE_KEYS = %w[
      schema releaseId version tag source authorization workflow
      expectedReleaseAssets subjects
    ].freeze
    SOURCE_KEYS = %w[repository commit].freeze
    AUTHORIZATION_KEYS = %w[repository commit mode].freeze
    WORKFLOW_KEYS = %w[repository runId runAttempt].freeze
    SUBJECT_KEYS = %w[role fileName sha256].freeze
    EXPECTED_KEYS = %w[version sourceSha authorizationSha].freeze
    ROLES = %w[
      package-tarball package-metadata distribution-manifest
      cyclonedx-sbom redistribution-evidence
    ].freeze
    STATIC_FILES = %w[
      package-artifact.json distribution-release.json sbom.cdx.json
      redistribution-evidence.json release-evidence.json
    ].freeze
    COMMIT = /\A[a-f0-9]{40}\z/.freeze
    SHA256 = /\A[a-f0-9]{64}\z/.freeze
    SEMVER = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/.freeze
    SENSITIVE = /secret-sentinel|bearer\s|cookie=|_authtoken|-----BEGIN .*PRIVATE KEY-----/i

    def verify!(release:, tag_reference:, tag_object:, directory:, config:, expected:)
      configuration = Configuration.parse(config)
      exact_keys(expected, EXPECTED_KEYS, "expected")
      version = pattern(expected.fetch("version"), SEMVER, "expected.version")
      fail_at("expected.version", "must not be a placeholder") if version == "0.0.0"
      source_sha = pattern(expected.fetch("sourceSha"), COMMIT, "expected.sourceSha")
      authorization_sha = pattern(
        expected.fetch("authorizationSha"),
        COMMIT,
        "expected.authorizationSha"
      )
      root = regular_directory(directory)

      verify_tag!(
        tag_reference,
        tag_object,
        version: version,
        source_sha: source_sha
      )

      fail_at("release", "must be an object") unless release.is_a?(Hash)
      equal(release.fetch("tag_name", nil), "cli-v#{version}", "release.tag_name")
      equal(release.fetch("immutable", nil), true, "release.immutable")
      equal(release.fetch("draft", nil), false, "release.draft")
      equal(release.fetch("prerelease", nil), false, "release.prerelease")

      evidence = read_json(root/"release-evidence.json", "release evidence")
      exact_keys(evidence, EVIDENCE_KEYS, "release evidence")
      equal(evidence.fetch("schema"), "crewcli.release-evidence/v2", "release evidence.schema")
      equal(evidence.fetch("releaseId"), configuration.release_id, "release evidence.releaseId")
      equal(evidence.fetch("version"), version, "release evidence.version")
      equal(evidence.fetch("tag"), "cli-v#{version}", "release evidence.tag")

      source = evidence.fetch("source")
      exact_keys(source, SOURCE_KEYS, "release evidence.source")
      equal(source.fetch("repository"), configuration.source_repository, "release evidence.source.repository")
      equal(source.fetch("commit"), source_sha, "release evidence.source.commit")

      authorization = evidence.fetch("authorization")
      exact_keys(authorization, AUTHORIZATION_KEYS, "release evidence.authorization")
      equal(
        authorization.fetch("repository"),
        configuration.source_repository,
        "release evidence.authorization.repository"
      )
      equal(authorization.fetch("commit"), authorization_sha, "release evidence.authorization.commit")
      equal(authorization.fetch("mode"), "repository-record", "release evidence.authorization.mode")

      workflow = evidence.fetch("workflow")
      exact_keys(workflow, WORKFLOW_KEYS, "release evidence.workflow")
      equal(workflow.fetch("repository"), configuration.source_repository, "release evidence.workflow.repository")
      pattern(workflow.fetch("runId"), /\A[1-9]\d*\z/, "release evidence.workflow.runId")
      unless workflow.fetch("runAttempt").is_a?(Integer) && workflow.fetch("runAttempt").positive?
        fail_at("release evidence.workflow.runAttempt", "must be a positive integer")
      end

      expected_assets = evidence.fetch("expectedReleaseAssets")
      unless expected_assets.is_a?(Array) && expected_assets.length == 6 && expected_assets.uniq.length == 6
        fail_at("release evidence.expectedReleaseAssets", "must contain the complete unique asset set")
      end
      artifact_names = expected_assets - STATIC_FILES
      unless artifact_names.length == 1 && safe_file_name?(artifact_names.first) &&
             artifact_names.first == "crewent-cli-#{version}.tgz" && expected_assets.last == "release-evidence.json"
        fail_at("release evidence.expectedReleaseAssets", "has an invalid identity")
      end
      artifact_name = artifact_names.first

      assets = release.fetch("assets", nil)
      fail_at("release.assets", "must be an array") unless assets.is_a?(Array)
      actual_assets = assets.map.with_index do |asset, index|
        validate_asset(asset, index, version, configuration.source_repository)
      end
      actual_names = actual_assets.map { |asset| asset.fetch("name") }
      unless actual_names.sort == expected_assets.sort && actual_names.uniq.length == actual_names.length
        fail_at("release.assets", "does not match release evidence")
      end
      actual_assets.each do |asset|
        digest = Digest::SHA256.file(regular_file(root/asset.fetch("name"), "release asset")).hexdigest
        equal(asset.fetch("digest"), "sha256:#{digest}", "release asset digest")
      end

      subjects = evidence.fetch("subjects")
      unless subjects.is_a?(Array) && subjects.length == 5
        fail_at("release evidence.subjects", "must contain five payload subjects")
      end
      payload_files = expected_assets.first(5)
      subjects.each_with_index do |subject, index|
        path = "release evidence.subjects[#{index}]"
        exact_keys(subject, SUBJECT_KEYS, path)
        equal(subject.fetch("role"), ROLES.fetch(index), "#{path}.role")
        equal(subject.fetch("fileName"), payload_files.fetch(index), "#{path}.fileName")
        expected_digest = pattern(subject.fetch("sha256"), SHA256, "#{path}.sha256")
        actual_digest = Digest::SHA256.file(regular_file(root/subject.fetch("fileName"), path)).hexdigest
        equal(actual_digest, expected_digest, "#{path}.sha256")
      end

      manifest_path = regular_file(root/"distribution-release.json", "distribution manifest")
      manifest_bytes = manifest_path.binread
      manifest = Manifest.parse(JSON.parse(manifest_bytes), config: configuration)
      equal(manifest.version, version, "manifest.version")
      equal(manifest.source_commit, source_sha, "manifest.source.commit")
      equal(manifest.artifact_file_name, artifact_name, "manifest.artifact.fileName")
      artifact_digest = Digest::SHA256.file(regular_file(root/artifact_name, "artifact")).hexdigest
      equal(manifest.artifact_sha256, artifact_digest, "manifest.artifact.sha256")

      {
        "schema" => "crewcli.homebrew-release-bundle/v1",
        "version" => version,
        "sourceSha" => source_sha,
        "authorizationSha" => authorization_sha,
        "artifactFileName" => artifact_name,
        "artifactSha256" => artifact_digest,
        "manifestSha256" => Digest::SHA256.hexdigest(manifest_bytes)
      }
    rescue KeyError, JSON::ParserError, ContractError
      fail_at("release bundle", "contains missing or invalid JSON fields")
    end

    def verify_tag!(reference, tag, version:, source_sha:)
      fail_at("tag reference", "must be an object") unless reference.is_a?(Hash)
      equal(reference.fetch("ref", nil), "refs/tags/cli-v#{version}", "tag reference.ref")
      reference_object = reference.fetch("object", nil)
      fail_at("tag reference.object", "must be an object") unless reference_object.is_a?(Hash)
      equal(reference_object.fetch("type", nil), "tag", "tag reference.object.type")
      tag_sha = pattern(reference_object.fetch("sha", nil), COMMIT, "tag reference.object.sha")

      fail_at("tag object", "must be an object") unless tag.is_a?(Hash)
      equal(tag.fetch("tag", nil), "cli-v#{version}", "tag object.tag")
      equal(tag.fetch("sha", nil), tag_sha, "tag object.sha")
      target = tag.fetch("object", nil)
      fail_at("tag object.object", "must be an object") unless target.is_a?(Hash)
      equal(target.fetch("type", nil), "commit", "tag object.object.type")
      equal(target.fetch("sha", nil), source_sha, "tag object.object.sha")
    end

    def validate_asset(asset, index, version, repository)
      path = "release.assets[#{index}]"
      fail_at(path, "must be an object") unless asset.is_a?(Hash)
      name = safe_string(asset.fetch("name", nil), "#{path}.name")
      fail_at("#{path}.name", "has an invalid format") unless safe_file_name?(name)
      equal(asset.fetch("state", nil), "uploaded", "#{path}.state")
      api_url = safe_string(asset.fetch("url", nil), "#{path}.url")
      browser_url = safe_string(asset.fetch("browser_download_url", nil), "#{path}.browser_download_url")
      digest = pattern(asset.fetch("digest", nil), /\Asha256:[a-f0-9]{64}\z/, "#{path}.digest")
      unless %r{\Ahttps://api\.github\.com/repos/#{Regexp.escape(repository)}/releases/assets/[1-9]\d*\z}.match?(api_url)
        fail_at("#{path}.url", "must be the exact source release asset API URL")
      end
      expected_browser = "https://github.com/#{repository}/releases/download/cli-v#{version}/#{name}"
      equal(browser_url, expected_browser, "#{path}.browser_download_url")
      { "name" => name, "digest" => digest }
    end

    def safe_file_name?(value)
      value.is_a?(String) && /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/.match?(value)
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

    def regular_directory(path)
      candidate = Pathname.new(path).expand_path
      state = candidate.lstat
      fail_at("directory", "must be a real directory") unless state.directory? && !state.symlink?
      candidate
    rescue Errno::ENOENT
      fail_at("directory", "must be a real directory")
    end

    def regular_file(path, label)
      candidate = Pathname.new(path).expand_path
      state = candidate.lstat
      fail_at(label, "must be a regular non-symlink file") unless state.file? && !state.symlink?
      candidate
    rescue Errno::ENOENT
      fail_at(label, "must be a regular non-symlink file")
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
      raise ReleaseBundleError, "#{path}: #{reason}"
    end

    def run(argv)
      allowed = %w[
        --release --tag-reference --tag-object --directory --config --version --source-sha
        --authorization-sha --output
      ]
      fail_at("arguments", "must be option/value pairs") unless argv.length == allowed.length * 2
      values = {}
      argv.each_slice(2) do |option, value|
        fail_at("arguments", "contains an unknown or duplicate option") unless allowed.include?(option) && !values.key?(option)
        values[option] = value
      end
      fail_at("arguments", "is incomplete") unless values.keys.sort == allowed.sort

      result = verify!(
        release: read_json(values.fetch("--release"), "release"),
        tag_reference: read_json(values.fetch("--tag-reference"), "tag reference"),
        tag_object: read_json(values.fetch("--tag-object"), "tag object"),
        directory: values.fetch("--directory"),
        config: read_json(values.fetch("--config"), "configuration"),
        expected: {
          "version" => values.fetch("--version"),
          "sourceSha" => values.fetch("--source-sha"),
          "authorizationSha" => values.fetch("--authorization-sha")
        }
      )
      write_atomic(values.fetch("--output"), result)
      result
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    CliDistribution::ReleaseBundle.run(ARGV)
  rescue CliDistribution::ReleaseBundleError => e
    warn "verify-release-bundle: #{e.message}"
    exit 1
  end
end
