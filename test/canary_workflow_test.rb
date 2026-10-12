# frozen_string_literal: true

require "minitest/autorun"

class CanaryWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../.github/workflows/canary.yml", __dir__)

  def setup
    @source = File.read(WORKFLOW)
  end

  def test_is_manual_with_exactly_four_inputs_and_three_blocking_targets
    assert_match(/^\s+workflow_dispatch:/, @source)
    refute_match(/^\s+(?:pull_request|push|schedule):/, @source)
    dispatch = @source.match(/workflow_dispatch:\n(?<body>.*?)\npermissions:/m)["body"]
    assert_equal %w[version sourceSha authorizationSha bottleRunId], dispatch.scan(/^ {6}(\w+):$/).flatten

    assert_equal %w[macos-arm64 linux-x86_64 linux-arm64], @source.scan(/^\s+- target: (\S+)$/).flatten
    assert_includes @source, "runner: macos-15"
    assert_includes @source, "runner: ubuntu-24.04"
    assert_includes @source, "runner: ubuntu-24.04-arm"
    refute_includes @source, "windows-wsl2"
    refute_includes @source, "self-hosted"
    assert_includes @source, "scripts/assert_canary_matrix.rb matrix"
  end

  def test_preflights_one_exact_successful_bottle_run_before_consumers
    fetch = @source.index("Fetch and preflight the exact bottle workflow run")
    download = @source.index("Download the exact bottle candidate")
    verify = @source.index("Validate the exact bottle candidate")
    upload = @source.index("Upload verified distribution inputs")
    assert fetch && download && verify && upload
    assert_operator fetch, :<, download
    assert_operator download, :<, verify
    assert_operator verify, :<, upload

    assert_includes @source, 'actions/runs/${BOTTLE_RUN_ID}'
    assert_includes @source, '.path == ".github/workflows/bottle.yml"'
    assert_includes @source, '.event == "workflow_dispatch"'
    assert_includes @source, '.head_branch == "main"'
    assert_includes @source, '.status == "completed" and .conclusion == "success"'
    assert_includes @source, '.head_sha == $bottleWorkflowSha'
    assert_includes @source, '.run_attempt == $bottleRunAttempt'
    assert_includes @source, "candidateFormulaSha256"
    assert_includes @source, "bottleMatrixSha256"
    assert_includes @source, "canary-inputs"
    assert_match(/^\s+canary:\n\s+needs: preflight/, @source)
  end

  def test_uses_only_four_shared_read_credentials
    secrets = @source.scan(/\$\{\{\s*secrets\.([A-Z0-9_]+)\s*\}\}/).flatten.uniq.sort
    assert_equal %w[
      CLI_GHCR_READ_TOKEN CLI_GHCR_READ_USER CLI_TAP_READ_TOKEN CLI_TAP_READ_USER
    ], secrets
    refute_includes @source, "secrets["
    refute_includes @source, "CLI_DISTRIBUTION_READER_APP"
    refute_includes @source, "CLI_RUNTIME_TOKEN"
    refute_includes @source, "CLI_CANARY_READ"
    refute_match(%r{https://[^\s$]+:[^\s$]+@github\.com}, @source)
    assert_includes @source, "GIT_CONFIG_VALUE_0"
    assert_includes @source, "HOMEBREW_DOCKER_REGISTRY_BASIC_AUTH_TOKEN"
  end

  def test_attests_actual_os_and_architecture_without_wsl2
    assert_includes @source, "uname -s"
    assert_includes @source, "uname -m"
    assert_includes @source, "host=macos"
    assert_includes @source, "host=linux"
    assert_includes @source, "verified:true"
    refute_includes @source, "powershell.exe"
    refute_includes @source, "microsoft-standard-WSL2"
  end

  def test_clones_private_tap_and_checks_bottle_only_lifecycle
    assert_includes @source, "git clone --no-tags https://github.com/zoe-llc/homebrew-crewcli.git"
    assert_includes @source, "cp \"$RUNNER_TEMP/canary-inputs/Formula/crewent.rb\""
    assert_operator @source.scan("brew install --force-bottle zoe-llc/crewcli/crewent").length, :>=, 2
    assert_includes @source, "crewent\" --version"
    assert_includes @source, "crewent\" --help"
    assert_includes @source, "crewcli\" --version"
    assert_operator @source.scan("brew uninstall crewent").length, :>=, 2
    assert_includes @source, "cleanRollbackPassed:true"
    assert_includes @source, "crewcli.homebrew-distribution-canary-lifecycle/v1"
  end

  def test_emits_distribution_evidence_without_product_or_source_harness
    assert_includes @source, "crewcli.homebrew-distribution-canary-expected/v1"
    assert_includes @source, "crewcli.homebrew-distribution-canary-evidence/v1"
    assert_includes @source, "distribution-canary-evidence"
    assert_includes @source, "Download all three closed target records"
    %w[step3-canary deploySha hostOrigin productSlug changeIntentNumber stale-ready phase-ab phase-c].each do |value|
      refute_includes @source, value
    end
    refute_includes @source, "release-inputs"
    refute_includes @source, "pnpm"
    refute_includes @source, "setup-node"
  end

  def test_has_no_write_permission_or_stable_mutation_and_pins_actions
    assert_includes @source, "actions: read"
    assert_includes @source, "contents: read"
    assert_equal 0, @source.scan(/^\s+(?:contents|packages|pull-requests|actions):\s+write\s*$/).length
    refute_match(/git\s+push|gh\s+pr\s+(?:create|merge)|brew\s+pr-upload/, @source)
    remote_uses = @source.scan(/^\s*-?\s*uses:\s*([^\s#]+)/).flatten.reject { |value| value.start_with?("./") }
    refute_empty remote_uses
    remote_uses.each { |value| assert_match(%r{\A[^@\s]+@[a-f0-9]{40}\z}, value) }
  end
end
