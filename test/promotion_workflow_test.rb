# frozen_string_literal: true

require "minitest/autorun"

class PromotionWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/promote.yml", __dir__)

  def setup
    @source = File.read(WORKFLOW)
  end

  def test_is_manual_and_pins_exact_bottle_and_distribution_canary_runs
    assert_match(/^\s+workflow_dispatch:/, @source)
    refute_match(/^\s+(?:pull_request|push|schedule):/, @source)
    dispatch = @source.match(/workflow_dispatch:\n(?<body>.*?)\npermissions:/m)["body"]
    assert_equal(
      %w[version sourceSha authorizationSha bottleRunId distributionCanaryRunId],
      dispatch.scan(/^ {6}(\w+):$/).flatten
    )
    refute_match(/^\s+canaryRunId:/, @source)
    assert_includes @source, "run-id: ${{ inputs.bottleRunId }}"
    assert_includes @source, "run-id: ${{ inputs.distributionCanaryRunId }}"
    assert_includes @source, 'actions/runs/${BOTTLE_RUN_ID}'
    assert_includes @source, 'actions/runs/${DISTRIBUTION_CANARY_RUN_ID}'
    assert_includes @source, '.path == ".github/workflows/bottle.yml"'
    assert_includes @source, '.path == ".github/workflows/canary.yml"'
    assert_operator @source.scan('.event == "workflow_dispatch"').length, :>=, 2
    assert_operator @source.scan('.status == "completed" and .conclusion == "success"').length, :>=, 2
  end

  def test_verifies_closed_three_target_distribution_evidence_only
    assert_includes @source, "distribution-canary-evidence"
    assert_includes @source, "crewcli.homebrew-distribution-canary-expected/v1"
    assert_includes @source, "crewcli.homebrew-distribution-canary-matrix/v1"
    assert_includes @source, "scripts/assert_canary_matrix.rb matrix"
    assert_includes @source, "targets/macos-arm64.json"
    assert_includes @source, "targets/linux-x86_64.json"
    assert_includes @source, "targets/linux-arm64.json"
    refute_includes @source, "windows-wsl2"
    %w[phase-ab phase-c deploySha hostOrigin productSlug changeIntentNumber stale-ready].each do |value|
      refute_includes @source, value
    end
  end

  def test_links_expected_evidence_to_the_exact_bottle_candidate
    assert_includes @source, '.bottleRunAttempt == $bottleRunAttempt'
    assert_includes @source, '.bottleWorkflowSha == $bottleWorkflowSha'
    assert_includes @source, '.bottles == $bottles'
    assert_includes @source, 'jq -c \'[.bottles[] | {key:.target,value:.bottle.sha256}] | from_entries\''
  end

  def test_separates_read_only_verification_from_the_single_write_job
    assert_match(/^  verify:\n(?:.|\n)*?    permissions:\n      actions: read\n      contents: read/m, @source)
    assert_match(/^  promote:\n    needs: verify/m, @source)
    assert_equal 1, @source.scan(/^\s+contents:\s+write\s*$/).length
    assert_equal 1, @source.scan(/^\s+pull-requests:\s+write\s*$/).length
    assert_equal 1, @source.scan(/^\s+actions:\s+write\s*$/).length
    refute_match(/^\s+packages:\s+write\s*$/, @source)
    assert_includes @source, "verified-promotion"
  end

  def test_revalidates_source_authorization_immediately_before_the_only_push
    reader = @source.rindex("actions/create-github-app-token@")
    verify = @source.rindex("scripts/verify_activation_window.rb")
    push = @source.index('git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${write_header}" push origin')
    dispatch = @source.index("actions/workflows/validate.yml/dispatches")
    validation_success = @source.index('test "$(jq -r .conclusion "$validation_run")" = "success"')
    create = @source.index("gh pr create")
    assert reader && verify && push && dispatch && validation_success && create
    assert_operator reader, :<, verify
    assert_operator verify, :<, push
    assert_operator push, :<, dispatch
    assert_operator dispatch, :<, validation_success
    assert_operator validation_success, :<, create
    assert_equal 1, @source.scan("push origin").length
    refute_match(/gh\s+pr\s+merge|--auto/, @source)
  end

  def test_promotes_only_formula_and_credential_free_distribution_evidence
    assert_includes @source, "Formula/crewent.rb"
    assert_includes @source, 'docs/verification/distribution-canary-${VERSION}.json'
    assert_includes @source, 'docs/verification/bottle-candidate-${VERSION}.json'
    assert_includes @source, ".identity.formulaSha256"
    assert_includes @source, "Digest::SHA256.file"
    assert_includes @source, "git diff --exit-code"
    assert_includes @source, "プライベート配布候補"
    assert_includes @source, "製品canaryはsource側で独立確認"
    assert_includes @source, "npm dist-tag is not used"
  end

  def test_pins_remote_actions_and_does_not_persist_checkout_credentials
    assert_includes @source, "persist-credentials: false"
    refute_includes @source, "persist-credentials: true"
    remote_uses = @source.scan(/^\s*-?\s*uses:\s*([^\s#]+)/).flatten.reject { |value| value.start_with?("./") }
    refute_empty remote_uses
    remote_uses.each { |value| assert_match(%r{\A[^@\s]+@[a-f0-9]{40}\z}, value) }
  end
end
