# frozen_string_literal: true

require "minitest/autorun"

class FormulaPolicyTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  FORMULA = File.join(ROOT, "Formula", "crewent.rb")

  def test_public_formula_surface_contains_only_crewent
    assert_equal [FORMULA], Dir.glob(File.join(ROOT, "Formula", "*.rb")).sort
  end

  def test_formula_preserves_exact_source_and_bottle_only_policy
    source = File.read(FORMULA)

    assert_includes source, "class Crewent < Formula"
    assert_includes source, 'homepage "https://github.com/zoe-llc/crewent"'
    assert_match(%r{url "https://github\.com/zoe-llc/crewent/releases/download/cli-v[^/]+/crewent-cli-[^"]+\.tgz"}, source)
    assert_includes source, 'ENV["HOMEBREW_CLI_DISTRIBUTION_BOTTLE_BUILD"] != "1"'
    assert_includes source, 'odie "Prebuilt bottle required; consumer source fallback is disabled"'
    assert_includes source, "package_root = buildpath"
    refute_includes source, 'buildpath/"package"'
    assert_includes source, 'odie "npm package metadata is missing" unless (package_root/"package.json").file?'
    assert_includes source, '["crewent", "crewcli"]'
    refute_match(/secrets\.|GH_TOKEN|GITHUB_TOKEN|HOMEBREW_GITHUB_API_TOKEN/, source)
    refute_match(/system\s+['"](?:curl|git|gh)['"]/, source)
  end
end
