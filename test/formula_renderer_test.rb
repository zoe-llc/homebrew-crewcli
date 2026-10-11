# frozen_string_literal: true

require "json"
require "minitest/autorun"

require_relative "../lib/cli_distribution/formula_renderer"

class FormulaRendererTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures", __dir__)
  CURRENT_CONFIG = {
    "schema" => "crewcli.homebrew-distribution/v1",
    "releaseId" => "phase2-cli",
    "sourceRepository" => "zoe-llc/crewcli",
    "formulaName" => "crewcli",
    "tap" => "zoe-llc/crewcli",
    "bottleRoot" => "https://ghcr.io/v2/zoe-llc/homebrew-crewcli"
  }.freeze
  ALTERNATE_CONFIG = CURRENT_CONFIG.merge(
    "sourceRepository" => "zoe-llc/sample-cli",
    "formulaName" => "sample-cli",
    "tap" => "zoe-llc/sample-cli",
    "bottleRoot" => "https://ghcr.io/v2/zoe-llc/homebrew-sample-cli"
  ).freeze

  def test_renders_deterministic_bottle_build_only_formula
    first = render("crewcli.distribution-release.v1.json", CURRENT_CONFIG)
    second = render("crewcli.distribution-release.v1.json", CURRENT_CONFIG)

    assert_equal first, second
    assert_match(/^class Crewcli < Formula$/, first)
    assert_includes first, 'url "https://github.com/zoe-llc/crewcli/releases/download/cli-v0.1.0/crewcli-cli-0.1.0.tgz"'
    assert_includes first, 'sha256 "c7c5c1d70c5dec4416ab6158afd0b223ef40c29b1dc1f97ed9428b94d4cadb1c"'
    assert_includes first, 'depends_on "node@22"'
    assert_includes first, 'ENV["HOMEBREW_CLI_DISTRIBUTION_BOTTLE_BUILD"] != "1"'
    assert_includes first, "Prebuilt bottle required; consumer source fallback is disabled"
    assert_includes first, 'JSON.parse((libexec/"package.json").read)'
    assert_includes first, '(bin/command).write_env_script entry, PATH: formula_opt_bin("node@22")'
    assert_includes first, 'expected_commands = ["crewcli"]'
    refute_match(/registry\.npmjs|npm install|--build-from-source/, first)
  end

  def test_renders_alternate_formula_without_current_mutable_names
    rendered = render("alternate-name.distribution-release.v1.json", ALTERNATE_CONFIG)

    assert_match(/^class SampleCli < Formula$/, rendered)
    assert_includes rendered, 'expected_commands = ["sample-cli", "sample"]'
    assert_includes rendered, "zoe-llc/sample-cli"
    refute_match(/@crewcli\/cli|\bcrewcli\b|homebrew-crewcli/, rendered)
  end

  def test_rejects_a_formula_name_that_cannot_map_to_one_class
    config = CURRENT_CONFIG.merge("formulaName" => "crewcli@next")

    assert_raises(CliDistribution::ContractError) do
      render("crewcli.distribution-release.v1.json", config)
    end
  end

  def test_checked_in_formula_matches_the_deterministic_candidate
    expected = render("crewcli.distribution-release.v1.json", CURRENT_CONFIG)
    actual = File.read(File.expand_path("../Formula/crewcli.rb", __dir__))

    assert_equal expected, actual
  end

  private

  def render(name, config)
    value = JSON.parse(File.read(File.join(FIXTURES, name)))
    CliDistribution::FormulaRenderer.render(value, config: config)
  end
end
