#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"
require "securerandom"

module CliDistribution
  class BottleMatrixError < TypeError; end

  module BottleMatrix
    module_function

    TARGETS = {
      "macos-arm64" => {
        "runner" => "macos-15",
        "os" => "macos",
        "architecture" => "arm64",
        "tag" => "arm64_sequoia"
      },
      "linux-x86_64" => {
        "runner" => "ubuntu-24.04",
        "os" => "linux",
        "architecture" => "x86_64",
        "tag" => "x86_64_linux"
      },
      "linux-arm64" => {
        "runner" => "ubuntu-24.04-arm",
        "os" => "linux",
        "architecture" => "arm64",
        "tag" => "arm64_linux"
      }
    }.freeze
    ENTRY_KEYS = %w[
      schema target status version sourceSha authorizationSha manifestSha256
      formulaSha256 runner os architecture bottle
    ].freeze
    BOTTLE_KEYS = %w[tag fileName sha256 blobUrl].freeze
    EXPECTED_KEYS = %w[version sourceSha authorizationSha manifestSha256 formulaSha256].freeze
    SEMVER = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/.freeze
    COMMIT = /\A[a-f0-9]{40}\z/.freeze
    SHA256 = /\A[a-f0-9]{64}\z/.freeze
    FILE_NAME = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/.freeze
    SENSITIVE = /secret-sentinel|bearer\s|cookie=|_authtoken|-----BEGIN .*PRIVATE KEY-----/i

    def assert!(entries, expected:)
      exact_keys(expected, EXPECTED_KEYS, "expected")
      validate_identity(expected, "expected")
      fail_at("entries", "must be an array") unless entries.is_a?(Array)
      fail_at("entries", "must contain exactly three targets") unless entries.length == TARGETS.length

      parsed = entries.map.with_index do |entry, index|
        parse_entry(entry, index, expected)
      end
      targets = parsed.map { |entry| entry.fetch("target") }
      unless targets.sort == TARGETS.keys.sort && targets.uniq.length == targets.length
        fail_at("entries.target", "must contain each supported target exactly once")
      end

      { "schema" => "crewcli.homebrew-bottle-matrix/v1" }
        .merge(EXPECTED_KEYS.to_h { |key| [key, expected.fetch(key)] })
        .merge("bottles" => parsed.sort_by { |entry| entry.fetch("target") })
    end

    def parse_entry(value, index, expected)
      path = "entries[#{index}]"
      exact_keys(value, ENTRY_KEYS, path)
      equal(value.fetch("schema"), "crewcli.homebrew-bottle-evidence/v1", "#{path}.schema")
      equal(value.fetch("status"), "PASS", "#{path}.status")
      EXPECTED_KEYS.each do |key|
        equal(value.fetch(key), expected.fetch(key), "#{path}.#{key}")
      end

      target = safe_string(value.fetch("target"), "#{path}.target")
      target_contract = TARGETS[target]
      fail_at("#{path}.target", "is not supported") unless target_contract
      %w[runner os architecture].each do |key|
        equal(value.fetch(key), target_contract.fetch(key), "#{path}.#{key}")
      end

      bottle = value.fetch("bottle")
      exact_keys(bottle, BOTTLE_KEYS, "#{path}.bottle")
      equal(bottle.fetch("tag"), target_contract.fetch("tag"), "#{path}.bottle.tag")
      file_name = safe_string(bottle.fetch("fileName"), "#{path}.bottle.fileName")
      fail_at("#{path}.bottle.fileName", "has an invalid format") unless FILE_NAME.match?(file_name)
      equal(
        file_name,
        "crewent--#{expected.fetch("version")}.#{target_contract.fetch("tag")}.bottle.tar.gz",
        "#{path}.bottle.fileName"
      )
      digest = pattern(bottle.fetch("sha256"), SHA256, "#{path}.bottle.sha256")
      expected_blob_url = "https://ghcr.io/v2/zoe-llc/homebrew-crewcli/crewent/blobs/sha256:#{digest}"
      equal(bottle.fetch("blobUrl"), expected_blob_url, "#{path}.bottle.blobUrl")

      JSON.parse(JSON.generate(value))
    end

    def validate_identity(value, path)
      version = pattern(value.fetch("version"), SEMVER, "#{path}.version")
      fail_at("#{path}.version", "must not be a placeholder") if version == "0.0.0"
      pattern(value.fetch("sourceSha"), COMMIT, "#{path}.sourceSha")
      pattern(value.fetch("authorizationSha"), COMMIT, "#{path}.authorizationSha")
      pattern(value.fetch("manifestSha256"), SHA256, "#{path}.manifestSha256")
      pattern(value.fetch("formulaSha256"), SHA256, "#{path}.formulaSha256")
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

    def fail_at(path, reason)
      raise BottleMatrixError, "#{path}: #{reason}"
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

    def run(argv)
      output_index = argv.index("--output")
      expected_index = argv.index("--expected")
      unless output_index && expected_index && argv.length == 7 && output_index + 1 < argv.length && expected_index + 1 < argv.length
        fail_at("arguments", "must be --expected FILE --output FILE EVIDENCE EVIDENCE EVIDENCE")
      end
      output = argv.fetch(output_index + 1)
      expected_path = argv.fetch(expected_index + 1)
      evidence_paths = argv.each_with_index.filter_map do |argument, index|
        next if [output_index, output_index + 1, expected_index, expected_index + 1].include?(index)
        argument
      end
      fail_at("arguments", "must contain three evidence files") unless evidence_paths.length == 3

      result = assert!(
        evidence_paths.map.with_index { |path, index| read_json(path, "evidence[#{index}]") },
        expected: read_json(expected_path, "expected")
      )
      write_atomic(output, result)
      result
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    CliDistribution::BottleMatrix.run(ARGV)
  rescue CliDistribution::BottleMatrixError => e
    warn "assert-bottle-matrix: #{e.message}"
    exit 1
  end
end
