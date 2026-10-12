# frozen_string_literal: true

require "minitest/autorun"

class CanaryWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/canary.yml", __dir__)

  def setup
    @source = File.read(WORKFLOW)
  end

  def test_is_manual_exact_and_has_all_four_blocking_consumers
    assert_match(/^\s+workflow_dispatch:/, @source)
    refute_match(/^\s+(?:pull_request|push|schedule):/, @source)
    %w[version sourceSha authorizationSha bottleRunId deploySha hostOrigin productSlug changeIntentNumber canarySha].each do |input|
      assert_match(/^\s+#{input}:/, @source)
    end
    %w[macos-arm64 linux-x86_64 linux-arm64 windows-wsl2].each do |target|
      assert_includes @source, target
    end
    assert_includes @source, '["self-hosted","windows","x64","wsl2","cli-wsl2-canary"]'
    assert_includes @source, "fail-fast: false"
    assert_includes @source, "scripts/assert_canary_matrix.rb matrix"
  end

  def test_downloads_one_exact_bottle_candidate_and_exact_source_harness
    assert_includes @source, "run-id: ${{ inputs.bottleRunId }}"
    assert_includes @source, "name: bottle-candidate"
    assert_includes @source, "name: release-inputs"
    assert_includes @source, "actions/create-github-app-token@"
    assert_includes @source, 'repos/zoe-llc/crewcli/tarball/${SOURCE_SHA}'
    assert_includes @source, "--filter @crewcli/phase2-contracts transit"
    assert_includes @source, "candidate.json"
    assert_includes @source, "bottle-matrix.json"
    assert_includes @source, 'actions/runs/${BOTTLE_RUN_ID}'
    assert_includes @source, '.path == ".github/workflows/bottle.yml"'
    assert_includes @source, '.event == "workflow_dispatch"'
    assert_includes @source, '.head_branch == "main"'
    assert_includes @source, '.status == "completed" and .conclusion == "success"'
    assert_includes @source, '.head_sha == $tapWorkflowSha'
    assert_includes @source, '.run_attempt == $bottleRunAttempt'
  end

  def test_attests_the_real_platform_instead_of_trusting_runner_labels
    assert_includes @source, "uname -s"
    assert_includes @source, "uname -m"
    assert_includes @source, "/proc/sys/kernel/osrelease"
    assert_includes @source, "microsoft-standard-WSL2"
    assert_includes @source, "powershell.exe -NoProfile"
    assert_includes @source, "Version.Build"
    assert_includes @source, "hostVerified:true"
    assert_includes @source, '--argjson platform "$(cat "$RUNNER_TEMP/platform-attestation.json")"'
    assert_includes @source, "platform:$platform"
  end

  def test_keeps_credentials_separate_and_out_of_git_urls
    %w[TAP_READ_USER TAP_READ_TOKEN GHCR_READ_USER GHCR_READ_TOKEN CANARY_READ_USER CANARY_READ_TOKEN CREWCLI_CANARY_ACCESS_TOKEN].each do |name|
      assert_includes @source, name
    end
    assert_includes @source, "secrets[matrix.tapUserSecret]"
    assert_includes @source, "secrets[matrix.runtimeTokenSecret]"
    refute_match(%r{https://[^\s$]+:[^\s$]+@github\.com}, @source)
    assert_includes @source, "GIT_CONFIG_VALUE_0"
    assert_includes @source, "HOMEBREW_DOCKER_REGISTRY_BASIC_AUTH_TOKEN"
  end

  def test_runs_ab_then_waits_for_exact_stale_marker_then_runs_c
    first_authorization = @source.index("scripts/verify_activation_window.rb")
    ab = @source.index("--phase ab")
    upload = @source.index("Upload sanitized A/B evidence")
    wait = @source.index("Wait for the exact stale-ready marker")
    second_authorization = @source.index("scripts/verify_activation_window.rb", first_authorization + 1)
    c = @source.index("--phase c")
    assert first_authorization && ab && upload && wait && second_authorization && c
    assert_operator first_authorization, :<, ab
    assert_operator ab, :<, upload
    assert_operator upload, :<, wait
    assert_operator wait, :<, c
    assert_operator wait, :<, second_authorization
    assert_operator second_authorization, :<, c
    assert_operator @source.scan("scripts/verify_activation_window.rb").length, :>=, 2
    assert_includes @source, 'cli-canary-stale-ready-${GITHUB_RUN_ID}'
    assert_includes @source, 'test "$marker_sha" = "$CANARY_SHA"'
  end

  def test_requires_bottle_install_runtime_alias_and_full_lifecycle
    assert_includes @source, "brew install --force-bottle zoe-llc/crewcli/crewent"
    assert_includes @source, "crewent --version"
    assert_includes @source, 'bin/crewent" --help'
    assert_includes @source, "crewcli --version"
    assert_includes @source, "brew upgrade zoe-llc/crewcli/crewent"
    assert_operator @source.scan("brew uninstall crewent").length, :>=, 2
    assert_operator @source.scan("brew install --force-bottle zoe-llc/crewcli/crewent").length, :>=, 2
    assert_includes @source, "initialRollbackClean"
  end

  def test_has_no_write_permission_or_stable_mutation
    assert_equal 0, @source.scan(/^\s+(?:contents|packages|pull-requests|actions):\s+write\s*$/).length
    refute_match(/git\s+push|gh\s+pr\s+(?:create|merge)|brew\s+pr-upload/, @source)
    remote_uses = @source.scan(/^\s*-?\s*uses:\s*([^\s#]+)/).flatten.reject { |value| value.start_with?("./") }
    refute_empty remote_uses
    remote_uses.each { |value| assert_match(%r{\A[^@\s]+@[a-f0-9]{40}\z}, value) }
  end
end
