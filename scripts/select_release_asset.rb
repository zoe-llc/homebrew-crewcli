#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"

require_relative "../lib/cli_distribution/release_asset"

module CliDistribution
  module SelectReleaseAsset
    module_function

    def run(argv)
      values = parse_arguments(argv)
      config = JSON.parse(regular_file(values.fetch("--config"), "configuration").read)
      release = JSON.parse(regular_file(values.fetch("--release"), "release").read)
      ReleaseAsset.manifest_asset_url(
        release,
        config: config,
        version: values.fetch("--version")
      )
    rescue JSON::ParserError
      Contract.fail_at("input", "must be valid JSON")
    end

    def parse_arguments(arguments)
      Contract.fail_at("arguments", "must be option/value pairs") unless arguments.length.even?
      values = {}
      arguments.each_slice(2) do |option, value|
        unless %w[--config --release --version].include?(option)
          Contract.fail_at("arguments", "contains an unknown option")
        end
        Contract.fail_at("arguments", "contains a duplicate option") if values.key?(option)
        if value.nil? || value.start_with?("--")
          Contract.fail_at("arguments", "contains an invalid value")
        end
        values[option] = value
      end
      unless values.keys.sort == %w[--config --release --version].sort
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
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    puts CliDistribution::SelectReleaseAsset.run(ARGV)
  rescue CliDistribution::ContractError => e
    warn "select-release-asset: #{e.message}"
    exit 1
  end
end
