# frozen_string_literal: true

require "minitest/autorun"

class PromotionWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/promote.yml", __dir__)

  def setup
    @source = File.read(WORKFLOW)
  end

  def test_is_manual_and_pins_bottle_and_canary_runs
    assert_match(/^\s+workflow_dispatch:/, @source)
    refute_match(/^\s+(?:pull_request|push|schedule):/, @source)
    %w[version sourceSha authorizationSha bottleRunId canaryRunId].each do |input|
      assert_match(/^\s+#{input}:/, @source)
    end
    assert_includes @source, "run-id: ${{ inputs.bottleRunId }}"
    assert_includes @source, "run-id: ${{ inputs.canaryRunId }}"
    assert_includes @source, "scripts/assert_canary_matrix.rb matrix"
    assert_includes @source, 'actions/runs/${BOTTLE_RUN_ID}'
    assert_includes @source, 'actions/runs/${CANARY_RUN_ID}'
    assert_includes @source, '.path == ".github/workflows/bottle.yml"'
    assert_includes @source, '.path == ".github/workflows/canary.yml"'
    assert_operator @source.scan('.event == "workflow_dispatch"').length, :>=, 2
    assert_operator @source.scan('.status == "completed" and .conclusion == "success"').length, :>=, 2
  end

  def test_revalidates_authorization_immediately_before_the_only_content_write
    verify = @source.rindex("scripts/verify_activation_window.rb")
    push = @source.index('git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${write_header}" push origin')
    dispatch = @source.index("actions/workflows/validate.yml/dispatches")
    validation_success = @source.index('test "$(jq -r .conclusion "$validation_run")" = "success"')
    create = @source.index("gh pr create")
    assert verify && push && dispatch && validation_success && create
    assert_operator verify, :<, push
    assert_operator push, :<, dispatch
    assert_operator dispatch, :<, validation_success
    assert_operator validation_success, :<, create
    assert_operator push, :<, create
    assert_equal 1, @source.scan("push origin").length
    refute_match(/gh\s+pr\s+merge|--auto/, @source)
  end

  def test_promotes_the_exact_candidate_formula_and_evidence_only_through_a_pr
    assert_includes @source, "candidate.json"
    assert_includes @source, "Formula/crewent.rb"
    assert_includes @source, "canary-matrix.json"
    assert_includes @source, "Digest::SHA256.file"
    assert_includes @source, "git diff --exit-code"
    assert_includes @source, "プライベート配布候補"
    assert_includes @source, "npm dist-tag"
    assert_includes @source, "is not used"
  end

  def test_remote_actions_are_commit_pinned_and_only_promotion_can_write
    assert_equal 1, @source.scan(/^\s+contents:\s+write\s*$/).length
    assert_equal 1, @source.scan(/^\s+pull-requests:\s+write\s*$/).length
    assert_equal 1, @source.scan(/^\s+actions:\s+write\s*$/).length
    refute_match(/^\s+packages:\s+write\s*$/, @source)
    assert_includes @source, "persist-credentials: false"
    refute_includes @source, "persist-credentials: true"
    remote_uses = @source.scan(/^\s*-?\s*uses:\s*([^\s#]+)/).flatten.reject { |value| value.start_with?("./") }
    refute_empty remote_uses
    remote_uses.each { |value| assert_match(%r{\A[^@\s]+@[a-f0-9]{40}\z}, value) }
  end
end
