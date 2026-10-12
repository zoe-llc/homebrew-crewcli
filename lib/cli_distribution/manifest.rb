# frozen_string_literal: true

require "uri"

module CliDistribution
  class ContractError < TypeError; end

  module Contract
    module_function

    SEMVER = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/.freeze
    REPOSITORY = /\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}\/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}\z/.freeze
    PACKAGE = /\A(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*\z/.freeze
    COMMAND = /\A[a-z0-9][a-z0-9._-]*\z/.freeze
    FORMULA = /\A[a-z0-9][a-z0-9._-]*\z/.freeze
    SHA256 = /\A[a-f0-9]{64}\z/.freeze
    COMMIT = /\A[a-f0-9]{40}\z/.freeze

    def object(value, path)
      fail_at(path, "must be an object") unless value.is_a?(Hash)
      value
    end

    def exact_keys(value, keys, path)
      object(value, path)
      missing = keys.reject { |key| value.key?(key) }
      extra = value.keys.reject { |key| keys.include?(key) }
      fail_at(path, "contains missing or unknown fields") unless missing.empty? && extra.empty?
    end

    def string(value, path)
      fail_at(path, "must be a string") unless value.is_a?(String)
      value
    end

    def pattern(value, expression, path)
      string(value, path)
      fail_at(path, "has an invalid format") unless expression.match?(value)
      value
    end

    def equal(value, expected, path)
      fail_at(path, "does not match the contract") unless value == expected
      value
    end

    def safe_https(value, host, path_pattern, path)
      string(value, path)
      uri = URI.parse(value)
      unless uri.scheme == "https" && uri.host == host && uri.userinfo.nil? && uri.port == 443 &&
             uri.query.nil? && uri.fragment.nil? && path_pattern.match?(uri.path)
        fail_at(path, "must be an exact credential-free HTTPS URL")
      end
      value
    rescue URI::InvalidURIError
      fail_at(path, "must be an exact credential-free HTTPS URL")
    end

    def fail_at(path, reason)
      raise ContractError, "#{path}: #{reason}"
    end
  end

  class Configuration
    KEYS = %w[schema releaseId sourceRepository formulaName tap bottleRoot].freeze

    attr_reader :release_id, :source_repository, :formula_name, :tap, :bottle_root

    def self.parse(value)
      return value if value.is_a?(self)

      Contract.exact_keys(value, KEYS, "config")
      Contract.equal(value["schema"], "crewcli.homebrew-distribution/v1", "config.schema")
      Contract.equal(value["releaseId"], "phase2-cli", "config.releaseId")
      Contract.pattern(value["sourceRepository"], Contract::REPOSITORY, "config.sourceRepository")
      Contract.pattern(value["formulaName"], Contract::FORMULA, "config.formulaName")
      tap = Contract.pattern(value["tap"], Contract::REPOSITORY, "config.tap")
      bottle_root = Contract.safe_https(
        value["bottleRoot"],
        "ghcr.io",
        %r{\A/v2/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z},
        "config.bottleRoot"
      )
      Contract.equal(bottle_root, "https://ghcr.io/v2/#{tap}", "config.bottleRoot")
      new(value)
    end

    def initialize(value)
      @release_id = value.fetch("releaseId").dup.freeze
      @source_repository = value.fetch("sourceRepository").dup.freeze
      @formula_name = value.fetch("formulaName").dup.freeze
      @tap = value.fetch("tap").dup.freeze
      @bottle_root = value.fetch("bottleRoot").dup.freeze
      freeze
    end

    private_class_method :new
  end

  class Manifest
    KEYS = %w[schema releaseId version source package artifact runtime].freeze
    SOURCE_KEYS = %w[repository commit].freeze
    PACKAGE_KEYS = %w[name].freeze
    ARTIFACT_KEYS = %w[type fileName url sha256].freeze
    RUNTIME_KEYS = %w[commands node].freeze
    COMMAND_KEYS = %w[primary aliases].freeze

    attr_reader :release_id, :version, :source_repository, :source_commit,
                :package_name, :artifact_file_name, :artifact_url,
                :artifact_sha256, :primary_command, :aliases, :node_requirement

    def self.parse(value, config:)
      configuration = Configuration.parse(config)
      Contract.exact_keys(value, KEYS, "manifest")
      Contract.equal(value["schema"], "crewcli.distribution-release/v1", "manifest.schema")
      Contract.equal(value["releaseId"], configuration.release_id, "manifest.releaseId")
      version = Contract.pattern(value["version"], Contract::SEMVER, "manifest.version")
      Contract.fail_at("manifest.version", "must not be a placeholder") if version == "0.0.0"

      source = value["source"]
      Contract.exact_keys(source, SOURCE_KEYS, "manifest.source")
      Contract.equal(source["repository"], configuration.source_repository, "manifest.source.repository")
      Contract.pattern(source["commit"], Contract::COMMIT, "manifest.source.commit")

      package = value["package"]
      Contract.exact_keys(package, PACKAGE_KEYS, "manifest.package")
      package_name = Contract.pattern(package["name"], Contract::PACKAGE, "manifest.package.name")

      artifact = value["artifact"]
      Contract.exact_keys(artifact, ARTIFACT_KEYS, "manifest.artifact")
      Contract.equal(artifact["type"], "npm-tarball", "manifest.artifact.type")
      file_name = tarball_name(package_name, version)
      Contract.equal(artifact["fileName"], file_name, "manifest.artifact.fileName")
      expected_url = "https://github.com/#{configuration.source_repository}/releases/download/cli-v#{version}/#{file_name}"
      Contract.equal(artifact["url"], expected_url, "manifest.artifact.url")
      Contract.safe_https(
        artifact["url"],
        "github.com",
        %r{\A/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/cli-v#{Regexp.escape(version)}/#{Regexp.escape(file_name)}\z},
        "manifest.artifact.url"
      )
      Contract.pattern(artifact["sha256"], Contract::SHA256, "manifest.artifact.sha256")

      runtime = value["runtime"]
      Contract.exact_keys(runtime, RUNTIME_KEYS, "manifest.runtime")
      commands = runtime["commands"]
      Contract.exact_keys(commands, COMMAND_KEYS, "manifest.runtime.commands")
      primary = Contract.pattern(commands["primary"], Contract::COMMAND, "manifest.runtime.commands.primary")
      aliases = commands["aliases"]
      Contract.fail_at("manifest.runtime.commands.aliases", "must be an array") unless aliases.is_a?(Array)
      aliases.each_with_index do |command, index|
        Contract.pattern(command, Contract::COMMAND, "manifest.runtime.commands.aliases[#{index}]")
      end
      all_commands = [primary] + aliases
      if all_commands.uniq.length != all_commands.length
        Contract.fail_at("manifest.runtime.commands", "must contain unique commands")
      end
      Contract.equal(runtime["node"], ">=22", "manifest.runtime.node")

      new(value, all_commands)
    end

    def self.tarball_name(package_name, version)
      stem = package_name.sub(/\A@/, "").tr("/", "-")
      "#{stem}-#{version}.tgz"
    end

    private_class_method def self.new(value, commands)
      super(value, commands)
    end

    def initialize(value, commands)
      @release_id = value.fetch("releaseId").dup.freeze
      @version = value.fetch("version").dup.freeze
      @source_repository = value.fetch("source").fetch("repository").dup.freeze
      @source_commit = value.fetch("source").fetch("commit").dup.freeze
      @package_name = value.fetch("package").fetch("name").dup.freeze
      @artifact_file_name = value.fetch("artifact").fetch("fileName").dup.freeze
      @artifact_url = value.fetch("artifact").fetch("url").dup.freeze
      @artifact_sha256 = value.fetch("artifact").fetch("sha256").dup.freeze
      @primary_command = commands.first.dup.freeze
      @aliases = commands.drop(1).map { |command| command.dup.freeze }.freeze
      @node_requirement = value.fetch("runtime").fetch("node").dup.freeze
      freeze
    end

    def commands
      [primary_command, *aliases]
    end
  end
end
