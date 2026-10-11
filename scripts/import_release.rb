#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"
require "securerandom"

require_relative "../lib/cli_distribution/formula_renderer"

module CliDistribution
  module ImportRelease
    module_function

    def run(argv)
      command, *arguments = argv
      Contract.fail_at("arguments", "command must be render or check") unless %w[render check].include?(command)
      values = parse_arguments(arguments)
      config_path = regular_file(values.fetch("--config"), "configuration")
      manifest_path = regular_file(values.fetch("--manifest"), "manifest")
      output_path = Pathname.new(values.fetch("--output")).expand_path
      config = JSON.parse(config_path.read)
      manifest = JSON.parse(manifest_path.read)
      rendered = FormulaRenderer.render(manifest, config: config)
      configuration = Configuration.parse(config)
      expected_name = "#{configuration.formula_name}.rb"
      unless output_path.basename.to_s == expected_name
        Contract.fail_at("arguments.output", "must match the configured Formula name")
      end

      if command == "check"
        unless regular_file(output_path, "output").read == rendered
          Contract.fail_at("output", "is not the deterministic Formula candidate")
        end
      else
        write_atomic(output_path, rendered)
      end
      rendered
    rescue JSON::ParserError
      Contract.fail_at("input", "must be valid JSON")
    end

    def parse_arguments(arguments)
      Contract.fail_at("arguments", "must be option/value pairs") unless arguments.length.even?
      values = {}
      arguments.each_slice(2) do |option, value|
        unless %w[--config --manifest --output].include?(option)
          Contract.fail_at("arguments", "contains an unknown option")
        end
        Contract.fail_at("arguments", "contains a duplicate option") if values.key?(option)
        if value.nil? || value.start_with?("--")
          Contract.fail_at("arguments", "contains an invalid value")
        end
        values[option] = value
      end
      unless values.keys.sort == %w[--config --manifest --output].sort
        Contract.fail_at("arguments", "is incomplete")
      end
      values
    end

    def regular_file(path, label)
      candidate = Pathname.new(path).expand_path
      state = candidate.lstat
      unless state.file? && !state.symlink?
        Contract.fail_at(label, "must be a regular non-symlink file")
      end
      candidate
    rescue Errno::ENOENT
      Contract.fail_at(label, "must be a regular non-symlink file")
    end

    def write_atomic(path, content)
      path.dirname.mkpath
      temporary = path.dirname/".#{path.basename}.#{Process.pid}.#{SecureRandom.hex(8)}.tmp"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(content)
        file.flush
        file.fsync
      end
      File.rename(temporary, path)
      File.open(path.dirname, File::RDONLY, &:fsync)
    ensure
      temporary&.delete if temporary&.exist?
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    output = CliDistribution::ImportRelease.run(ARGV)
    $stdout.write(output) if ARGV.first == "check"
  rescue CliDistribution::ContractError => e
    warn "import-release: #{e.message}"
    exit 1
  end
end
