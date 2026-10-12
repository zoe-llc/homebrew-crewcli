# frozen_string_literal: true

require "minitest/autorun"

class BottleWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/bottle.yml", __dir__)

  def test_is_manual_exact_and_uses_the_fixed_three_target_matrix
    source = File.read(WORKFLOW)

    assert_match(/^\s+workflow_dispatch:/, source)
    refute_match(/^\s+(?:pull_request|push|schedule):/, source)
    %w[version sourceSha authorizationSha].each do |input|
      assert_match(/^\s+#{input}:/, source)
    end
    assert_includes source, "github.ref == 'refs/heads/main'"
    assert_includes source, "macos-15"
    assert_includes source, "ubuntu-24.04"
    assert_includes source, "ubuntu-24.04-arm"
    refute_includes source, "macos-latest"
    refute_includes source, "ubuntu-latest"
  end

  def test_reads_the_exact_immutable_source_release_with_the_reader_app
    source = File.read(WORKFLOW)

    assert_includes source, "actions/create-github-app-token@"
    assert_includes source, "repositories: crewcli"
    assert_includes source, "permission-contents: read"
    assert_includes source, "crewent-distribution-reader"
    assert_includes source, "scripts/verify_release_bundle.rb"
    assert_includes source, "scripts/verify_activation_window.rb"
    assert_includes source, "release-evidence.json"
    assert_includes source, "distribution-release.json"
    assert_includes source, "authorizationSha"
    assert_includes source, "scripts/import_release.rb render"
  end

  def test_builds_and_tests_exact_bottles_without_registry_or_source_fallback
    source = File.read(WORKFLOW)

    assert_includes source, "HOMEBREW_CLI_DISTRIBUTION_BOTTLE_BUILD: \"1\""
    assert_includes source, "brew install --build-bottle"
    assert_includes source, "brew test"
    assert_includes source, "bin/crewent"
    assert_includes source, "--version"
    assert_includes source, "--help"
    assert_includes source, "bin/crewcli"
    assert_includes source, "brew bottle --json"
    assert_includes source, "scripts/assert_bottle_matrix.rb"
    assert_includes source, "registry.npmjs.org"
    refute_match(/npm\s+(?:install|publish)|pnpm\s+(?:install|publish)/, source)
  end

  def test_only_publish_job_has_package_write_and_all_remote_actions_are_pinned
    source = File.read(WORKFLOW)

    assert_equal 1, source.scan(/^\s+packages:\s+write\s*$/).length
    remote_uses = source.scan(/^\s*-?\s*uses:\s*([^\s#]+)/).flatten.reject do |value|
      value.start_with?("./")
    end
    refute_empty remote_uses
    remote_uses.each do |value|
      assert_match(%r{\A[^@\s]+@[a-f0-9]{40}\z}, value)
    end
  end

  def test_never_pushes_or_merges_stable_formula_from_the_build_workflow
    source = File.read(WORKFLOW)

    refute_match(/git\s+push|gh\s+pr\s+(?:create|merge)/, source)
    assert_includes source, "brew pr-upload"
    assert_includes source, "actions/upload-artifact@"
    assert_includes source, "bottle-candidate"
  end
end
