#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "securerandom"
require "time"
require "uri"

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
      },
      "windows-wsl2" => {
        "label" => "self-hosted,windows,x64,wsl2,cli-wsl2-canary",
        "os" => "linux", "architecture" => "x86_64", "host" => "windows11-wsl2"
      }
    }.freeze
    EXPECTED_KEYS = %w[
      schema version sourceSha authorizationSha artifactSha256 manifestSha256 formulaSha256
      bottleMatrixSha256 bottles deploySha hostOrigin productSlug changeIntentNumber
      canaryRepository canarySha bottleRunId workflowRepository workflowRunId workflowRunAttempt
      tapWorkflowSha
    ].freeze
    IDENTITY_KEYS = %w[
      version sourceSha authorizationSha artifactSha256 manifestSha256 formulaSha256
      bottleMatrixSha256 bottles deploySha hostOrigin productSlug changeIntentNumber
      canaryRepository canarySha
    ].freeze
    WORKFLOW_KEYS = %w[repository runId runAttempt headSha bottleRunId].freeze
    TARGET_KEYS = %w[
      schema target status timestamp identity runner installation runtime lifecycle evidence workflow
    ].freeze
    INSTALLATION_KEYS = %w[
      tapAuthenticated ghcrAuthenticated bottleOnly versionMatched helpMatched aliasMatched
    ].freeze
    RUNTIME_KEYS = %w[loginSucceeded phaseAPassed phaseBPassed phaseCPassed staleNoRebind].freeze
    LIFECYCLE_KEYS = %w[upgradePassed uninstallPassed reinstallPassed initialRollbackClean].freeze
    EVIDENCE_KEYS = %w[phaseAbSha256 phaseCSha256].freeze
    PLATFORM_KEYS = %w[os architecture host hostVerified].freeze
    SEMVER = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/.freeze
    COMMIT = /\A[a-f0-9]{40}\z/.freeze
    SHA256 = /\A[a-f0-9]{64}\z/.freeze
    SLUG = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/.freeze
    REPOSITORY = /\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}\z/.freeze
    RUN_ID = /\A[1-9]\d*\z/.freeze
    SENSITIVE = /secret-sentinel|bearer\s|authorization\s*[:=]|cookie\s*[:=]|_authtoken|-----BEGIN .*PRIVATE KEY-----/i
    MAX_AGE_SECONDS = 7_200
    MAX_FUTURE_SKEW_SECONDS = 300

    def build_target(target:, expected:, phase_ab:, phase_c:, lifecycle:, phase_ab_sha256:, phase_c_sha256:, now: Time.now.utc)
      validate_expected(expected)
      contract = TARGETS[target]
      fail_at("target", "is not supported") unless contract
      validate_phase!(phase_ab, "ab", expected)
      validate_phase!(phase_c, "c", expected)
      validate_phase_relationship!(phase_ab, phase_c)
      validate_lifecycle!(lifecycle, target)
      pattern(phase_ab_sha256, SHA256, "phaseAbSha256")
      pattern(phase_c_sha256, SHA256, "phaseCSha256")

      result = {
        "schema" => "crewcli.homebrew-canary-evidence/v1",
        "target" => target,
        "status" => "PASS",
        "timestamp" => canonical_time(now),
        "identity" => expected_identity(expected),
        "runner" => JSON.parse(JSON.generate(contract.merge("verified" => true))),
        "installation" => lifecycle.fetch("installation"),
        "runtime" => RUNTIME_KEYS.to_h { |key| [key, true] },
        "lifecycle" => lifecycle.fetch("lifecycle"),
        "evidence" => { "phaseAbSha256" => phase_ab_sha256, "phaseCSha256" => phase_c_sha256 },
        "workflow" => expected_workflow(expected)
      }
      reject_sensitive!(result, "targetEvidence")
      JSON.parse(JSON.generate(result))
    end

    def assert_matrix!(entries, expected:, now: Time.now.utc)
      validate_expected(expected)
      fail_at("entries", "must be an array") unless entries.is_a?(Array)
      fail_at("entries", "must contain exactly four targets") unless entries.length == TARGETS.length
      parsed = entries.map.with_index do |entry, index|
        validate_target!(entry, expected, now, "entries[#{index}]")
      end
      targets = parsed.map { |entry| entry.fetch("target") }
      unless targets.sort == TARGETS.keys.sort && targets.uniq.length == targets.length
        fail_at("entries.target", "must contain each supported target exactly once")
      end
      result = {
        "schema" => "crewcli.homebrew-canary-matrix/v1",
        "createdAt" => canonical_time(now),
        "identity" => expected_identity(expected),
        "workflow" => expected_workflow(expected),
        "targets" => parsed.sort_by { |entry| entry.fetch("target") }
      }
      reject_sensitive!(result, "matrix")
      result
    end

    def validate_expected(value)
      exact_keys(value, EXPECTED_KEYS, "expected")
      equal(value.fetch("schema"), "crewcli.homebrew-canary-expected/v1", "expected.schema")
      version = pattern(value.fetch("version"), SEMVER, "expected.version")
      fail_at("expected.version", "must not be a placeholder") if version == "0.0.0"
      %w[sourceSha authorizationSha deploySha canarySha].each do |key|
        pattern(value.fetch(key), COMMIT, "expected.#{key}")
      end
      %w[artifactSha256 manifestSha256 formulaSha256 bottleMatrixSha256].each do |key|
        pattern(value.fetch(key), SHA256, "expected.#{key}")
      end
      bottles = value.fetch("bottles")
      exact_keys(bottles, %w[macos-arm64 linux-x86_64 linux-arm64], "expected.bottles")
      bottles.each { |key, digest| pattern(digest, SHA256, "expected.bottles.#{key}") }
      validate_origin(value.fetch("hostOrigin"), "expected.hostOrigin")
      pattern(value.fetch("productSlug"), SLUG, "expected.productSlug")
      positive_integer(value.fetch("changeIntentNumber"), "expected.changeIntentNumber")
      repository(value.fetch("canaryRepository"), "expected.canaryRepository")
      equal(value.fetch("canaryRepository"), "zoe-llc/cli-distribution-canary", "expected.canaryRepository")
      repository(value.fetch("workflowRepository"), "expected.workflowRepository")
      equal(value.fetch("workflowRepository"), "zoe-llc/homebrew-crewcli", "expected.workflowRepository")
      pattern(value.fetch("bottleRunId"), RUN_ID, "expected.bottleRunId")
      pattern(value.fetch("workflowRunId"), RUN_ID, "expected.workflowRunId")
      positive_integer(value.fetch("workflowRunAttempt"), "expected.workflowRunAttempt")
      pattern(value.fetch("tapWorkflowSha"), COMMIT, "expected.tapWorkflowSha")
      reject_sensitive!(value, "expected")
      value
    end

    def validate_phase!(value, phase, expected)
      path = "phase#{phase.upcase}"
      exact_keys(value, %w[schema timestamp identity release phase runs], path)
      equal(value.fetch("schema"), "crewcli.distribution-canary-evidence/v1", "#{path}.schema")
      equal(value.fetch("phase"), phase, "#{path}.phase")
      parse_time(value.fetch("timestamp"), "#{path}.timestamp")
      identity = value.fetch("identity")
      exact_keys(
        identity,
        %w[cliVersion packageSha256 manifestSha256 hostOrigin repository productSlug changeIntentNumber],
        "#{path}.identity"
      )
      {
        "cliVersion" => "version", "packageSha256" => "artifactSha256",
        "manifestSha256" => "manifestSha256", "hostOrigin" => "hostOrigin",
        "repository" => "canaryRepository", "productSlug" => "productSlug",
        "changeIntentNumber" => "changeIntentNumber"
      }.each do |actual, expected_key|
        equal(identity.fetch(actual), expected.fetch(expected_key), "#{path}.identity.#{actual}")
      end
      release = value.fetch("release")
      exact_keys(release, %w[workflowSha deploySha], "#{path}.release")
      equal(release.fetch("workflowSha"), expected.fetch("sourceSha"), "#{path}.release.workflowSha")
      equal(release.fetch("deploySha"), expected.fetch("deploySha"), "#{path}.release.deploySha")
      runs = value.fetch("runs")
      if phase == "ab"
        exact_keys(runs, %w[a b], "#{path}.runs")
        validate_run!(runs.fetch("a"), 0, %w[identityMatched treeUnchanged contextVerified], "#{path}.runs.a")
        validate_run!(runs.fetch("b"), 0, %w[identityMatched treeUnchanged sameSession sameContext], "#{path}.runs.b")
      else
        exact_keys(runs, ["c"], "#{path}.runs")
        validate_run!(
          runs.fetch("c"), 3,
          %w[identityMatched treeUnchanged staleRejected sessionUnchanged contextUnchanged],
          "#{path}.runs.c"
        )
      end
      reject_sensitive!(value, path)
    end

    def validate_run!(value, exit_code, assertion_keys, path)
      exact_keys(value, %w[exitCode sessionId publishedRevisionId contextHash assertions], path)
      equal(value.fetch("exitCode"), exit_code, "#{path}.exitCode")
      %w[sessionId publishedRevisionId].each do |key|
        safe_string(value.fetch(key), "#{path}.#{key}")
        fail_at("#{path}.#{key}", "must not be empty") if value.fetch(key).empty?
      end
      fail_at("#{path}.contextHash", "is invalid") unless /\Asha256:[a-f0-9]{64}\z/.match?(value.fetch("contextHash"))
      assertions = value.fetch("assertions")
      exact_keys(assertions, assertion_keys, "#{path}.assertions")
      assertion_keys.each { |key| equal(assertions.fetch(key), true, "#{path}.assertions.#{key}") }
    end

    def validate_phase_relationship!(phase_ab, phase_c)
      b = phase_ab.fetch("runs").fetch("b")
      c = phase_c.fetch("runs").fetch("c")
      %w[sessionId publishedRevisionId contextHash].each do |key|
        equal(c.fetch(key), b.fetch(key), "phaseC.runs.c.#{key}")
      end
    end

    def validate_lifecycle!(value, target)
      exact_keys(value, %w[schema target platform installation lifecycle], "lifecycle")
      equal(value.fetch("schema"), "crewcli.homebrew-canary-lifecycle/v1", "lifecycle.schema")
      equal(value.fetch("target"), target, "lifecycle.target")
      platform = value.fetch("platform")
      exact_keys(platform, PLATFORM_KEYS, "lifecycle.platform")
      expected_platform = TARGETS.fetch(target).reject { |key, _value| key == "label" }.merge("hostVerified" => true)
      equal(platform, expected_platform, "lifecycle.platform")
      assert_true_object(value.fetch("installation"), INSTALLATION_KEYS, "lifecycle.installation")
      assert_true_object(value.fetch("lifecycle"), LIFECYCLE_KEYS, "lifecycle.lifecycle")
      reject_sensitive!(value, "lifecycle")
    end

    def validate_target!(value, expected, now, path)
      exact_keys(value, TARGET_KEYS, path)
      equal(value.fetch("schema"), "crewcli.homebrew-canary-evidence/v1", "#{path}.schema")
      equal(value.fetch("status"), "PASS", "#{path}.status")
      target = safe_string(value.fetch("target"), "#{path}.target")
      contract = TARGETS[target]
      fail_at("#{path}.target", "is not supported") unless contract
      timestamp = parse_time(value.fetch("timestamp"), "#{path}.timestamp")
      fail_at("#{path}.timestamp", "is stale") if now - timestamp > MAX_AGE_SECONDS
      fail_at("#{path}.timestamp", "is in the future") if timestamp - now > MAX_FUTURE_SKEW_SECONDS
      equal(value.fetch("identity"), expected_identity(expected), "#{path}.identity")
      equal(value.fetch("runner"), contract.merge("verified" => true), "#{path}.runner")
      assert_true_object(value.fetch("installation"), INSTALLATION_KEYS, "#{path}.installation")
      assert_true_object(value.fetch("runtime"), RUNTIME_KEYS, "#{path}.runtime")
      assert_true_object(value.fetch("lifecycle"), LIFECYCLE_KEYS, "#{path}.lifecycle")
      evidence = value.fetch("evidence")
      exact_keys(evidence, EVIDENCE_KEYS, "#{path}.evidence")
      evidence.each { |key, digest| pattern(digest, SHA256, "#{path}.evidence.#{key}") }
      equal(value.fetch("workflow"), expected_workflow(expected), "#{path}.workflow")
      reject_sensitive!(value, path)
      JSON.parse(JSON.generate(value))
    end

    def expected_identity(expected)
      IDENTITY_KEYS.to_h { |key| [key, JSON.parse(JSON.generate(expected.fetch(key)))] }
    end

    def expected_workflow(expected)
      {
        "repository" => expected.fetch("workflowRepository"),
        "runId" => expected.fetch("workflowRunId"),
        "runAttempt" => expected.fetch("workflowRunAttempt"),
        "headSha" => expected.fetch("tapWorkflowSha"),
        "bottleRunId" => expected.fetch("bottleRunId")
      }
    end

    def assert_true_object(value, keys, path)
      exact_keys(value, keys, path)
      keys.each { |key| equal(value.fetch(key), true, "#{path}.#{key}") }
    end

    def validate_origin(value, path)
      safe_string(value, path)
      uri = URI.parse(value)
      unless uri.is_a?(URI::HTTPS) && uri.host && uri.path.to_s.empty? && !uri.userinfo && !uri.query && !uri.fragment
        fail_at(path, "must be an HTTPS origin")
      end
    rescue URI::InvalidURIError
      fail_at(path, "must be an HTTPS origin")
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

    def read_json(path, label)
      candidate = Pathname.new(path).expand_path
      state = candidate.lstat
      fail_at(label, "must be a regular non-symlink file") unless state.file? && !state.symlink?
      [JSON.parse(candidate.read), Digest::SHA256.file(candidate).hexdigest]
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
        names = %w[--target --expected --phase-ab --phase-c --lifecycle --output]
        options = parse_named(arguments, names)
        fail_at("arguments", "contains unexpected positional arguments") unless arguments.empty?
        expected, = read_json(options.fetch("--expected"), "expected")
        phase_ab, phase_ab_sha256 = read_json(options.fetch("--phase-ab"), "phaseAb")
        phase_c, phase_c_sha256 = read_json(options.fetch("--phase-c"), "phaseC")
        lifecycle, = read_json(options.fetch("--lifecycle"), "lifecycle")
        result = build_target(
          target: options.fetch("--target"), expected: expected, phase_ab: phase_ab, phase_c: phase_c,
          lifecycle: lifecycle, phase_ab_sha256: phase_ab_sha256, phase_c_sha256: phase_c_sha256, now: now
        )
        write_atomic(options.fetch("--output"), result)
        result
      when "matrix"
        options = parse_named(arguments, %w[--expected --output])
        fail_at("arguments", "must contain exactly four target files") unless arguments.length == TARGETS.length
        expected, = read_json(options.fetch("--expected"), "expected")
        entries = arguments.map.with_index { |path, index| read_json(path, "evidence[#{index}]").first }
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
