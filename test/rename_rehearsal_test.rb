# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "../lib/cli_distribution/formula_renderer"

class RenameRehearsalTest < Minitest::Test
  CURRENT_CONFIG = {
    "schema" => "crewcli.homebrew-distribution/v1",
    "releaseId" => "phase2-cli",
    "sourceRepository" => "zoe-llc/crewent",
    "formulaName" => "crewent",
    "tap" => "zoe-llc/crewcli",
    "bottleRoot" => "https://ghcr.io/v2/zoe-llc/crewcli"
  }.freeze
  FUTURE_CONFIG = CURRENT_CONFIG.merge(
    "formulaName" => "future-name",
    "tap" => "zoe-llc/future-name",
    "bottleRoot" => "https://ghcr.io/v2/zoe-llc/future-name"
  ).freeze
  SOURCE_COMMIT = "0123456789abcdef0123456789abcdef01234567"

  def test_rehearses_formula_command_bottle_and_rollback_without_overwriting_history
    Dir.mktmpdir("crewent-homebrew-rename-") do |root|
      formula_directory = File.join(root, "Formula")
      bottle_directory = File.join(root, "bottles")
      FileUtils.mkdir_p(formula_directory)
      FileUtils.mkdir_p(bottle_directory)

      current_formula = render(manifest(
        version: "0.1.0",
        package: "@crewent/cli",
        primary: "crewent",
        aliases: ["crewcli"],
        digest: "a" * 64
      ), CURRENT_CONFIG)
      current_formula_path = File.join(formula_directory, "crewent.rb")
      current_bottle_path = File.join(bottle_directory, "crewent--0.1.0.arm64_sequoia.bottle.tar.gz")
      File.write(current_formula_path, current_formula)
      File.binwrite(current_bottle_path, "immutable-crewent-bottle-0.1.0\n")
      current_snapshot = snapshot(current_formula_path, current_bottle_path)

      future_formula = render(manifest(
        version: "0.2.0",
        package: "@future-name/cli",
        primary: "future-name",
        aliases: ["crewent"],
        digest: "b" * 64
      ), FUTURE_CONFIG)
      future_formula_path = File.join(formula_directory, "future-name.rb")
      future_bottle_path = File.join(bottle_directory, "future-name--0.2.0.arm64_sequoia.bottle.tar.gz")
      File.write(future_formula_path, future_formula)
      File.binwrite(future_bottle_path, "new-future-name-bottle-0.2.0\n")
      renames = { "crewcli" => "future-name", "crewent" => "future-name" }
      File.write(File.join(root, "formula_renames.json"), "#{JSON.pretty_generate(renames)}\n")

      assert_equal current_snapshot, snapshot(current_formula_path, current_bottle_path)
      assert File.file?(future_formula_path)
      assert File.file?(future_bottle_path)
      refute_equal Digest::SHA256.file(current_bottle_path).hexdigest,
                   Digest::SHA256.file(future_bottle_path).hexdigest
      assert_includes future_formula, 'expected_commands = ["future-name", "crewent"]'
      assert_equal renames, JSON.parse(File.read(File.join(root, "formula_renames.json")))
      assert_equal "future-name", renames.fetch("crewcli")
      assert_equal "future-name", renames.fetch("crewent")

      rollback_formula = File.read(current_formula_path)
      rollback_bottle_sha256 = Digest::SHA256.file(current_bottle_path).hexdigest
      assert_equal current_snapshot.fetch(:formula_bytes), rollback_formula
      assert_equal current_snapshot.fetch(:bottle_sha256), rollback_bottle_sha256
    end
  end

  private

  def manifest(version:, package:, primary:, aliases:, digest:)
    file_name = "#{package.delete_prefix("@").tr("/", "-")}-#{version}.tgz"
    {
      "schema" => "crewcli.distribution-release/v1",
      "releaseId" => "phase2-cli",
      "version" => version,
      "source" => { "repository" => "zoe-llc/crewent", "commit" => SOURCE_COMMIT },
      "package" => { "name" => package },
      "artifact" => {
        "type" => "npm-tarball",
        "fileName" => file_name,
        "url" => "https://github.com/zoe-llc/crewent/releases/download/cli-v#{version}/#{file_name}",
        "sha256" => digest
      },
      "runtime" => {
        "commands" => { "primary" => primary, "aliases" => aliases },
        "node" => ">=22"
      }
    }
  end

  def render(value, config)
    CliDistribution::FormulaRenderer.render(value, config: config)
  end

  def snapshot(formula_path, bottle_path)
    {
      formula_bytes: File.binread(formula_path),
      formula_sha256: Digest::SHA256.file(formula_path).hexdigest,
      bottle_bytes: File.binread(bottle_path),
      bottle_sha256: Digest::SHA256.file(bottle_path).hexdigest
    }
  end
end
