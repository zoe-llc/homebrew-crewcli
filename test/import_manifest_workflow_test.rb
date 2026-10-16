# frozen_string_literal: true

require "minitest/autorun"

class ImportManifestWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/import-manifest.yml", __dir__)

  def test_remote_actions_are_pinned_to_full_commit_shas
    remote_uses = File.read(WORKFLOW).scan(/^\s*-?\s*uses:\s*([^\s#]+)/).flatten.reject do |value|
      value.start_with?("./")
    end

    refute_empty remote_uses
    remote_uses.each do |value|
      assert_match(%r{\A[^@\s]+@[a-f0-9]{40}\z}, value)
    end
  end

  def test_manual_workflow_derives_an_immutable_release_from_exact_version
    source = File.read(WORKFLOW)

    assert_match(/^\s+workflow_dispatch:/, source)
    refute_match(/^\s+(?:pull_request|push):/, source)
    assert_includes source, "if: github.ref == 'refs/heads/main'"
    assert_match(/^\s+version:/, source)
    refute_match(/manifest_path:/, source)
    refute_match(%r{/contents/}, source)
    assert_includes source, "scripts/select_release_asset.rb"
    assert_includes source, "scripts/import_release.rb render"
    assert_includes source, "crewent.rb"
  end

  def test_token_is_scoped_to_the_exact_read_only_installation
    source = File.read(WORKFLOW)

    assert_includes source, "repositories: crewent"
    assert_includes source, 'repos/zoe-llc/crewent/releases/tags/${tag}'
    refute_includes source, 'repos/zoe-llc/crewcli/releases/tags/${tag}'
    assert_includes source, "permission-contents: read"
    assert_includes source, "steps.app-token.outputs.installation-id"
    assert_includes source, "secrets.CLI_DISTRIBUTION_READER_APP_INSTALLATION_ID"
    assert_includes source, 'test "$ACTUAL_APP_SLUG" = "crewent-distribution-reader"'
    assert_includes source, 'test "$ACTUAL_INSTALLATION_ID" = "$EXPECTED_INSTALLATION_ID"'
  end
end
