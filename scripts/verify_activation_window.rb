#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"
require "securerandom"
require "time"
require "uri"

module CliDistribution
  class ActivationWindowError < TypeError; end

  module ActivationWindow
    module_function

    ROOT_KEYS = %w[
      schema decision version sourceSha gates activationWindow actors
      authorization rollback
    ].freeze
    EXPECTED_KEYS = %w[version sourceSha authorizationSha executor].freeze
    GATE_KEYS = %w[id result evidenceUrl].freeze
    WINDOW_KEYS = %w[startsAt endsAt].freeze
    ACTOR_KEYS = %w[executor authorizationOwner releaseOwner rollbackOwner].freeze
    AUTHORIZATION_KEYS = %w[mode independentReviewerRequired].freeze
    ROLLBACK_KEYS = %w[point].freeze
    ANCESTRY_KEYS = %w[authorizationOnDevelop sourceToAuthorization].freeze
    COMPARISON_KEYS = %w[baseSha head mergeBaseSha status].freeze
    GATE_IDS = %w[
      distribution-config-release-workflow
      release-authorization-boundary
      manifest-reader-app
      public-tap-anonymous-access
      private-ghcr-access
      license-sbom-redistribution
      bottle-build-runners
      three-target-distribution-activation
      dedicated-canary-target
      retention-rollback-activation-window
    ].freeze
    SEMVER = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/.freeze
    ROLLBACK = /\A(?:stable-unavailable|cli-v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))\z/.freeze
    COMMIT = /\A[a-f0-9]{40}\z/.freeze
    IDENTITY = /\Agithub:[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/.freeze
    SENSITIVE = /secret-sentinel|bearer\s|cookie=|_authtoken|-----BEGIN .*PRIVATE KEY-----/i

    def verify!(value, expected:, ancestry:, now: Time.now.utc)
      exact_keys(value, ROOT_KEYS, "activation")
      exact_keys(expected, EXPECTED_KEYS, "expected")
      equal(value.fetch("schema"), "crewcli.internal-activation-window/v2", "activation.schema")
      equal(value.fetch("decision"), "PASS", "activation.decision")
      version = pattern(expected.fetch("version"), SEMVER, "expected.version")
      fail_at("expected.version", "must not be a placeholder") if version == "0.0.0"
      source_sha = pattern(expected.fetch("sourceSha"), COMMIT, "expected.sourceSha")
      authorization_sha = pattern(expected.fetch("authorizationSha"), COMMIT, "expected.authorizationSha")
      executor = pattern(expected.fetch("executor"), IDENTITY, "expected.executor")
      verify_ancestry!(
        ancestry,
        source_sha: source_sha,
        authorization_sha: authorization_sha
      )
      equal(value.fetch("version"), version, "activation.version")
      equal(value.fetch("sourceSha"), source_sha, "activation.sourceSha")

      gates = value.fetch("gates")
      fail_at("activation.gates", "must contain all ten gates") unless gates.is_a?(Array) && gates.length == GATE_IDS.length
      observed_ids = gates.map.with_index do |gate, index|
        path = "activation.gates[#{index}]"
        exact_keys(gate, GATE_KEYS, path)
        id = safe_string(gate.fetch("id"), "#{path}.id")
        equal(gate.fetch("result"), "PASS", "#{path}.result")
        evidence_url(gate.fetch("evidenceUrl"), "#{path}.evidenceUrl")
        id
      end
      equal(observed_ids, GATE_IDS, "activation.gates")

      window = value.fetch("activationWindow")
      exact_keys(window, WINDOW_KEYS, "activation.activationWindow")
      starts_at = parse_time(window.fetch("startsAt"), "activation.activationWindow.startsAt")
      ends_at = parse_time(window.fetch("endsAt"), "activation.activationWindow.endsAt")
      fail_at("activation.activationWindow", "must be ordered and currently open") unless starts_at < ends_at && now >= starts_at && now <= ends_at

      actors = value.fetch("actors")
      exact_keys(actors, ACTOR_KEYS, "activation.actors")
      ACTOR_KEYS.each do |key|
        pattern(actors.fetch(key), IDENTITY, "activation.actors.#{key}")
      end
      equal(actors.fetch("executor"), executor, "activation.actors.executor")

      authorization = value.fetch("authorization")
      exact_keys(authorization, AUTHORIZATION_KEYS, "activation.authorization")
      equal(authorization.fetch("mode"), "repository-record", "activation.authorization.mode")
      equal(
        authorization.fetch("independentReviewerRequired"),
        false,
        "activation.authorization.independentReviewerRequired"
      )

      rollback = value.fetch("rollback")
      exact_keys(rollback, ROLLBACK_KEYS, "activation.rollback")
      rollback_point = safe_string(rollback.fetch("point"), "activation.rollback.point")
      unless ROLLBACK.match?(rollback_point)
        fail_at("activation.rollback.point", "is invalid")
      end

      {
        "schema" => "crewcli.homebrew-activation-authorization/v1",
        "version" => version,
        "sourceSha" => source_sha,
        "authorizationSha" => authorization_sha,
        "executor" => executor,
        "startsAt" => starts_at.iso8601,
        "endsAt" => ends_at.iso8601,
        "rollbackPoint" => rollback_point
      }
    rescue KeyError
      fail_at("activation", "contains missing fields")
    end

    def verify_ancestry!(value, source_sha:, authorization_sha:)
      exact_keys(value, ANCESTRY_KEYS, "ancestry")
      verify_comparison!(
        value.fetch("authorizationOnDevelop"),
        path: "ancestry.authorizationOnDevelop",
        base_sha: authorization_sha,
        head: "develop",
        merge_base_sha: authorization_sha
      )
      verify_comparison!(
        value.fetch("sourceToAuthorization"),
        path: "ancestry.sourceToAuthorization",
        base_sha: source_sha,
        head: authorization_sha,
        merge_base_sha: source_sha
      )
    end

    def verify_comparison!(value, path:, base_sha:, head:, merge_base_sha:)
      exact_keys(value, COMPARISON_KEYS, path)
      equal(value.fetch("baseSha"), base_sha, "#{path}.baseSha")
      equal(value.fetch("head"), head, "#{path}.head")
      equal(value.fetch("mergeBaseSha"), merge_base_sha, "#{path}.mergeBaseSha")
      status = safe_string(value.fetch("status"), "#{path}.status")
      fail_at("#{path}.status", "must prove ancestor or identical history") unless %w[ahead identical].include?(status)
    end

    def evidence_url(value, path)
      safe_string(value, path)
      uri = URI.parse(value)
      segments = uri.path.split("/").reject(&:empty?)
      unless uri.scheme == "https" && uri.host == "github.com" && uri.userinfo.nil? &&
             uri.query.nil? && uri.fragment.nil? && segments[0, 3] == %w[zoe-llc crewent blob] &&
             COMMIT.match?(segments.fetch(3, "")) && segments[4, 2] == %w[docs verification] &&
             segments.length >= 7
        fail_at(path, "must be an exact source verification URL")
      end
      value
    rescue URI::InvalidURIError
      fail_at(path, "must be an exact source verification URL")
    end

    def parse_time(value, path)
      safe_string(value, path)
      parsed = Time.iso8601(value)
      fail_at(path, "must include an explicit offset") unless /(?:Z|[+-]\d{2}:\d{2})\z/.match?(value)
      parsed
    rescue ArgumentError
      fail_at(path, "must be an ISO 8601 timestamp with offset")
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

    def read_json(path)
      candidate = Pathname.new(path).expand_path
      state = candidate.lstat
      fail_at("evidence", "must be a regular non-symlink file") unless state.file? && !state.symlink?
      JSON.parse(candidate.read)
    rescue Errno::ENOENT, JSON::ParserError
      fail_at("evidence", "must be a regular valid JSON file")
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
      raise ActivationWindowError, "#{path}: #{reason}"
    end

    def run(argv)
      allowed = %w[--evidence --ancestry --version --source-sha --authorization-sha --executor --output]
      fail_at("arguments", "must be option/value pairs") unless argv.length == allowed.length * 2
      values = {}
      argv.each_slice(2) do |option, value|
        fail_at("arguments", "contains an unknown or duplicate option") unless allowed.include?(option) && !values.key?(option)
        values[option] = value
      end
      fail_at("arguments", "is incomplete") unless values.keys.sort == allowed.sort

      result = verify!(
        read_json(values.fetch("--evidence")),
        expected: {
          "version" => values.fetch("--version"),
          "sourceSha" => values.fetch("--source-sha"),
          "authorizationSha" => values.fetch("--authorization-sha"),
          "executor" => values.fetch("--executor")
        },
        ancestry: read_json(values.fetch("--ancestry"))
      )
      write_atomic(values.fetch("--output"), result)
      result
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    CliDistribution::ActivationWindow.run(ARGV)
  rescue CliDistribution::ActivationWindowError => e
    warn "verify-activation-window: #{e.message}"
    exit 1
  end
end
