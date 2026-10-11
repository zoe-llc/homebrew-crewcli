# frozen_string_literal: true

require "json"

require_relative "manifest"

module CliDistribution
  module FormulaRenderer
    module_function

    def render(value, config:)
      configuration = Configuration.parse(config)
      manifest = Manifest.parse(value, config: configuration)
      class_name = formula_class(configuration.formula_name)
      commands = manifest.commands.map { |command| JSON.generate(command) }.join(", ")

      <<~RUBY
        # frozen_string_literal: true

        require "json"

        # Internal CLI distribution Formula.
        class #{class_name} < Formula
          desc "Internal CLI distribution"
          homepage "https://github.com/#{manifest.source_repository}"
          url #{JSON.generate(manifest.artifact_url)}
          sha256 #{JSON.generate(manifest.artifact_sha256)}
          license :cannot_represent

          depends_on "node@22"

          def install
            if ENV["HOMEBREW_CLI_DISTRIBUTION_BOTTLE_BUILD"] != "1"
              odie "Prebuilt bottle required; consumer source fallback is disabled"
            end

            package_root = buildpath/"package"
            odie "npm package root is missing" unless package_root.directory?
            libexec.install package_root.children

            metadata = JSON.parse((libexec/"package.json").read)
            bin_map = metadata.fetch("bin")
            expected_commands = [#{commands}]
            if bin_map.keys.sort != expected_commands.sort
              odie "package command set does not match the release manifest"
            end

            expected_commands.each do |command|
              relative = bin_map.fetch(command)
              parts = relative.is_a?(String) ? relative.delete_prefix("./").split("/") : []
              safe_parts = parts.any? && parts.none? do |part|
                part.empty? || part == "." || part == ".." || !part.match?(/\\A[A-Za-z0-9_.-]+\\z/)
              end
              odie "package command path is unsafe" unless safe_parts
              entry = libexec.join(*parts).cleanpath
              odie "package command escapes libexec" unless entry.to_s.start_with?("\#{libexec}/")
              (bin/command).write_env_script entry, PATH: formula_opt_bin("node@22")
            end
          end

          test do
            assert_match version.to_s, shell_output("\#{bin}/#{manifest.primary_command} --version")
            assert_match "Usage:", shell_output("\#{bin}/#{manifest.primary_command} --help")
          end
        end
      RUBY
    end

    def formula_class(name)
      Contract.pattern(name, Contract::FORMULA, "config.formulaName")
      parts = name.split(/[._-]/)
      Contract.fail_at("config.formulaName", "cannot map to a Formula class") if parts.any?(&:empty?)
      class_name = parts.map { |part| part[0].upcase + part[1..-1] }.join
      unless /\A[A-Z][A-Za-z0-9]*\z/.match?(class_name)
        Contract.fail_at("config.formulaName", "cannot map to a Formula class")
      end
      class_name
    end
  end
end
