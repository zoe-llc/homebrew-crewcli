# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "../scripts/import_release"

class ImportReleaseTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_renders_and_checks_only_local_contract_files
    Dir.mktmpdir("tap-import-") do |directory|
      output = File.join(directory, "crewcli.rb")
      arguments = [
        "--config", File.join(ROOT, "config/distribution.json"),
        "--manifest", File.join(ROOT, "test/fixtures/crewcli.distribution-release.v1.json"),
        "--output", output
      ]

      rendered = CliDistribution::ImportRelease.run(["render", *arguments])
      assert_equal rendered, File.read(output)
      assert_equal rendered, CliDistribution::ImportRelease.run(["check", *arguments])

      File.write(output, "drift\n")
      assert_raises(CliDistribution::ContractError) do
        CliDistribution::ImportRelease.run(["check", *arguments])
      end
      assert_equal "drift\n", File.read(output)
      assert_empty Dir.glob(File.join(directory, ".*.tmp"))
    end
  end

  def test_rejects_symlink_input_and_wrong_formula_output_name
    Dir.mktmpdir("tap-import-") do |directory|
      manifest = File.join(ROOT, "test/fixtures/crewcli.distribution-release.v1.json")
      linked_manifest = File.join(directory, "manifest.json")
      File.symlink(manifest, linked_manifest)

      assert_raises(CliDistribution::ContractError) do
        CliDistribution::ImportRelease.run(
          [
            "render",
            "--config", File.join(ROOT, "config/distribution.json"),
            "--manifest", linked_manifest,
            "--output", File.join(directory, "crewcli.rb")
          ]
        )
      end

      assert_raises(CliDistribution::ContractError) do
        CliDistribution::ImportRelease.run(
          [
            "render",
            "--config", File.join(ROOT, "config/distribution.json"),
            "--manifest", manifest,
            "--output", File.join(directory, "other.rb")
          ]
        )
      end
    end
  end
end
