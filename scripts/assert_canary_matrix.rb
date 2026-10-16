#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "securerandom"
require "time"

module CliDistribution
  class CanaryMatrixError < TypeError; end

  module CanaryMatrix
    module_function

    TARGETS = {
      "macos-arm64" => {
        "label" => "macos-15", "os" => "macos", "architecture" => "arm64", "host" => "macos"
      },
      "linux-x86_64" => {
        "label" => "ubuntu-24.04", "os" => "linux", "architecture" => "x86_64", "host" => "linux"
      },
      "linux-arm64" => {
        "label" => "ubuntu-24.04-arm", "os" => "linux", "architecture" => "arm64", "host" => "linux"
      }
    }.freeze
    EXPECTED_KEYS = %w[
      schema version sourceSha authorizationSha artifactSha256 manifestSha256 formulaSha256
      bottleMatrixSha256 bottles bottleRunId bottleRunAttempt bottleWorkflowSha workflowRepository
      workflowRunId workflowRunAttempt workflowSha
    ].freeze
    IDENTITY_KEYS = %w[
      version sourceSha authorizationSha artifactSha256 manifestSha256 formulaSha256 bottleMatrixSha256 bottles
    ].freeze
    TARGET_KEYS = %w[
      schema target status timestamp identity producer workflow platform installation commands lifecycle
    ].freeze
    PLATFORM_KEYS = %w[os architecture host verified].freeze
    INSTALLATION_KEYS = %w[tapAccess ghcrAccess bottleOnly].freeze
    COMMAND_KEYS = %w[primaryVersionMatched primaryHelpMatched aliasVersionMatched].freeze
    LIFECYCLE_KEYS = %w[uninstallPassed reinstallPassed cleanRollbackPassed].freeze
    RUN_KEYS = %w[repository workflowPath event branch runId runAttempt headSha].freeze
    SEMVER = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/.freeze
    COMMIT = /\A[a-f0-9]{40}\z/.freeze
    SHA256 = /\A[a-f0-9]{64}\z/.freeze
    REPOSITORY = /\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}\z/.freeze
    RUN_ID = /\A[1-9]\d*\z/.freeze
    SENSITIVE = %r{
      secret-sentinel|bearer\s|authorization\s*[:=]|cookie\s*[:=]|_authtoken|
      -----BEGIN\ .*PRIVATE\ KEY-----|https?://[^\s/:@]+:[^@\s/]+@|gh[pousr]_[A-Za-z0-9_]{20,}
    }ix.freeze
    MAX_AGE_SECONDS = 7_200
    MAX_FUTURE_SKEW_SECONDS = 300

    def build_target(target:, expected:, lifecycle:, now: Time.now.utc)
      validate_expected(expected)
      contract = TARGETS[target]
      fail_at("target", "is not supported") unless contract
      validate_lifecycle!(lifecycle, target)

      result = {
        "schema" => "crewcli.homebrew-distribution-canary-evidence/v1",
        "target" => target,
        "status" => "PASS",
        "timestamp" => canonical_time(now),
        "identity" => expected_identity(expected),
        "producer" => expected_producer(expected),
        "workflow" => expected_workflow(expected),
        "platform" => deep_copy(contract.merge("verified" => true)),
        "installation" => deep_copy(lifecycle.fetch("installation")),
        "commands" => deep_copy(lifecycle.fetch("commands")),
        "lifecycle" => deep_copy(lifecycle.fetch("lifecycle"))
      }
      reject_sensitive!(result, "targetEvidence")
      result
    end

    def assert_matrix!(entries, expected:, now: Time.now.utc)
      validate_expected(expected)
      fail_at("entries", "must be an array") unless entries.is_a?(Array)
      fail_at("entries", "must contain exactly three targets") unless entries.length == TARGETS.length
      parsed = entries.map.with_index do |entry, index|
        validate_target!(entry, expected, now, "entries[#{index}]")
      end
      targets = parsed.map { |entry| entry.fetch("target") }
      unless targets.sort == TARGETS.keys.sort && targets.uniq.length == targets.length
        fail_at("entries.target", "must contain each supported target exactly once")
      end

      result = {
        "schema" => "crewcli.homebrew-distribution-canary-matrix/v1",
        "createdAt" => canonical_time(now),
        "identity" => expected_identity(expected),
        "producer" => expected_producer(expected),
        "workflow" => expected_workflow(expected),
        "targets" => parsed.sort_by { |entry| entry.fetch("target") }
      }
      reject_sensitive!(result, "matrix")
      result
    end

    def validate_expected(value)
      exact_keys(value, EXPECTED_KEYS, "expected")
      equal(value.fetch("schema"), "crewcli.homebrew-distribution-canary-expected/v1", "expected.schema")
      version = pattern(value.fetch("version"), SEMVER, "expected.version")
      fail_at("expected.version", "must not be a placeholder") if version == "0.0.0"
      %w[sourceSha authorizationSha bottleWorkflowSha workflowSha].each do |key|
        pattern(value.fetch(key), COMMIT, "expected.#{key}")
      end
      %w[artifactSha256 manifestSha256 formulaSha256 bottleMatrixSha256].each do |key|
        pattern(value.fetch(key), SHA256, "expected.#{key}")
      end
      bottles = value.fetch("bottles")
      exact_keys(bottles, TARGETS.keys, "expected.bottles")
      bottles.each { |key, digest| pattern(digest, SHA256, "expected.bottles.#{key}") }
      %w[bottleRunId workflowRunId].each do |key|
        pattern(value.fetch(key), RUN_ID, "expected.#{key}")
      end
      %w[bottleRunAttempt workflowRunAttempt].each do |key|
        positive_integer(value.fetch(key), "expected.#{key}")
      end
      repository(value.fetch("workflowRepository"), "expected.workflowRepository")
      equal(value.fetch("workflowRepository"), "zoe-llc/homebrew-crewcli", "expected.workflowRepository")
      reject_sensitive!(value, "expected")
      value
    end

    def validate_lifecycle!(value, target)
      exact_keys(value, %w[schema target platform installation commands lifecycle], "lifecycle")
      equal(
        value.fetch("schema"), "crewcli.homebrew-distribution-canary-lifecycle/v1", "lifecycle.schema"
      )
      equal(value.fetch("target"), target, "lifecycle.target")
      expected_platform = TARGETS.fetch(target).reject { |key, _value| key == "label" }.merge("verified" => true)
      exact_keys(value.fetch("platform"), PLATFORM_KEYS, "lifecycle.platform")
      equal(value.fetch("platform"), expected_platform, "lifecycle.platform")
      assert_installation(value.fetch("installation"), "lifecycle.installation")
      assert_true_object(value.fetch("commands"), COMMAND_KEYS, "lifecycle.commands")
      assert_true_object(value.fetch("lifecycle"), LIFECYCLE_KEYS, "lifecycle.lifecycle")
      reject_sensitive!(value, "lifecycle")
      value
    end

    def validate_target!(value, expected, now, path)
      exact_keys(value, TARGET_KEYS, path)
      equal(value.fetch("schema"), "crewcli.homebrew-distribution-canary-evidence/v1", "#{path}.schema")
      equal(value.fetch("status"), "PASS", "#{path}.status")
      target = safe_string(value.fetch("target"), "#{path}.target")
      contract = TARGETS[target]
      fail_at("#{path}.target", "is not supported") unless contract
      timestamp = parse_time(value.fetch("timestamp"), "#{path}.timestamp")
      fail_at("#{path}.timestamp", "is stale") if now - timestamp > MAX_AGE_SECONDS
      fail_at("#{path}.timestamp", "is in the future") if timestamp - now > MAX_FUTURE_SKEW_SECONDS
      equal(value.fetch("identity"), expected_identity(expected), "#{path}.identity")
      equal(value.fetch("producer"), expected_producer(expected), "#{path}.producer")
      equal(value.fetch("workflow"), expected_workflow(expected), "#{path}.workflow")
      equal(value.fetch("platform"), contract.merge("verified" => true), "#{path}.platform")
      assert_installation(value.fetch("installation"), "#{path}.installation")
      assert_true_object(value.fetch("commands"), COMMAND_KEYS, "#{path}.commands")
      assert_true_object(value.fetch("lifecycle"), LIFECYCLE_KEYS, "#{path}.lifecycle")
      reject_sensitive!(value, path)
      deep_copy(value)
    end

    def expected_identity(expected)
      IDENTITY_KEYS.to_h { |key| [key, deep_copy(expected.fetch(key))] }
    end

    def expected_producer(expected)
      {
        "repository" => expected.fetch("workflowRepository"),
        "workflowPath" => ".github/workflows/bottle.yml",
        "event" => "workflow_dispatch",
        "branch" => "main",
        "runId" => expected.fetch("bottleRunId"),
        "runAttempt" => expected.fetch("bottleRunAttempt"),
        "headSha" => expected.fetch("bottleWorkflowSha")
      }
    end

    def expected_workflow(expected)
      {
        "repository" => expected.fetch("workflowRepository"),
        "workflowPath" => ".github/workflows/canary.yml",
        "event" => "workflow_dispatch",
        "branch" => "main",
        "runId" => expected.fetch("workflowRunId"),
        "runAttempt" => expected.fetch("workflowRunAttempt"),
        "headSha" => expected.fetch("workflowSha")
      }
    end

    def assert_true_object(value, keys, path)
      exact_keys(value, keys, path)
      keys.each { |key| equal(value.fetch(key), true, "#{path}.#{key}") }
    end

    def assert_installation(value, path)
      exact_keys(value, INSTALLATION_KEYS, path)
      equal(value.fetch("tapAccess"), "anonymous-public", "#{path}.tapAccess")
      equal(value.fetch("ghcrAccess"), "authenticated-private", "#{path}.ghcrAccess")
      equal(value.fetch("bottleOnly"), true, "#{path}.bottleOnly")
    end

    def canonical_time(value)
      value.utc.iso8601(3)
    end

    def parse_time(value, path)
      safe_string(value, path)
      parsed = Time.iso8601(value)
      fail_at(path, "must be canonical UTC") unless value == parsed.utc.iso8601(3)
      parsed
    rescue ArgumentError
      fail_at(path, "must be canonical UTC")
    end

    def positive_integer(value, path)
      fail_at(path, "must be a positive integer") unless value.is_a?(Integer) && value.positive?
      value
    end

    def repository(value, path)
      pattern(value, REPOSITORY, path)
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
      fail_at(path, "does not match the contract") unless value == expected
      value
    end

    def reject_sensitive!(value, path)
      case value
      when Hash
        value.each { |key, child| reject_sensitive!(child, "#{path}.#{key}") }
      when Array
        value.each_with_index { |child, index| reject_sensitive!(child, "#{path}[#{index}]") }
      when String
        fail_at(path, "contains prohibited sensitive data") if SENSITIVE.match?(value)
      end
    end

    def fail_at(path, reason)
      raise CanaryMatrixError, "#{path}: #{reason}"
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def read_json(path, label)
      candidate = Pathname.new(path).expand_path
      state = candidate.lstat
      fail_at(label, "must be a regular non-symlink file") unless state.file? && !state.symlink?
      JSON.parse(candidate.read)
    rescue Errno::ENOENT, JSON::ParserError
      fail_at(label, "must be a regular valid JSON file")
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

    def parse_named(arguments, names)
      options = {}
      while arguments.first&.start_with?("--")
        key = arguments.shift
        fail_at("arguments", "contains an unknown option") unless names.include?(key)
        fail_at("arguments", "contains a duplicate option") if options.key?(key)
        value = arguments.shift
        fail_at("arguments", "contains a missing option value") unless value && !value.start_with?("--")
        options[key] = value
      end
      missing = names.reject { |name| options.key?(name) }
      fail_at("arguments", "contains missing options") unless missing.empty?
      options
    end

    def run(argv, now: Time.now.utc)
      arguments = argv.dup
      command = arguments.shift
      case command
      when "target"
        options = parse_named(arguments, %w[--target --expected --lifecycle --output])
        fail_at("arguments", "contains unexpected positional arguments") unless arguments.empty?
        expected = read_json(options.fetch("--expected"), "expected")
        lifecycle = read_json(options.fetch("--lifecycle"), "lifecycle")
        result = build_target(
          target: options.fetch("--target"), expected: expected, lifecycle: lifecycle, now: now
        )
        write_atomic(options.fetch("--output"), result)
        result
      when "matrix"
        options = parse_named(arguments, %w[--expected --output])
        fail_at("arguments", "must contain exactly three target files") unless arguments.length == TARGETS.length
        expected = read_json(options.fetch("--expected"), "expected")
        entries = arguments.map.with_index { |path, index| read_json(path, "evidence[#{index}]") }
        result = assert_matrix!(entries, expected: expected, now: now)
        write_atomic(options.fetch("--output"), result)
        result
      else
        fail_at("arguments", "command must be target or matrix")
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    CliDistribution::CanaryMatrix.run(ARGV)
  rescue CliDistribution::CanaryMatrixError => e
    warn "assert-canary-matrix: #{e.message}"
    exit 1
  end
end
