# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

class PublicRepositoryPolicyTest < Minitest::Test
  WORKFLOW_DIRECTORY = File.expand_path("../.github/workflows", __dir__)
  EXPECTED_WORKFLOWS = ["validate.yml"].freeze
  WORKFLOW_GLOB = "*.{yml,yaml}"

  def setup
    @workflows = workflow_sources(WORKFLOW_DIRECTORY)
  end

  def test_live_repository_is_formula_only_and_secret_free
    assert_empty policy_errors(@workflows)
  end

  def test_rejects_an_additional_pull_request_workflow
    workflows = @workflows.merge("extra.yaml" => workflow.sub("name: Validate public Tap", "name: Extra"))

    assert_includes policy_errors(workflows), "workflow file set must be exactly validate.yml"
  end

  def test_discovers_both_yml_and_yaml_workflow_extensions
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "validate.yml"), "name: Validate\n")
      File.write(File.join(directory, "extra.yaml"), "name: Extra\n")

      assert_equal %w[extra.yaml validate.yml], workflow_sources(directory).keys
    end
  end

  def test_rejects_top_level_write_permission
    invalid = workflow.sub("permissions:\n  contents: read", "permissions:\n  contents: write")

    assert_includes policy_errors("validate.yml" => invalid),
                    "validate.yml: top-level permissions must be contents: read only"
  end

  def test_rejects_job_level_package_permission_even_when_read_only
    invalid = workflow.sub(
      "    runs-on: ubuntu-24.04",
      "    permissions:\n      packages: read\n    runs-on: ubuntu-24.04"
    )

    assert_includes policy_errors("validate.yml" => invalid),
                    "validate.yml: packages permission is forbidden"
  end

  def test_rejects_any_secret_reference
    invalid = workflow.sub(
      "  HOMEBREW_NO_AUTO_UPDATE: \"1\"",
      "  HOMEBREW_NO_AUTO_UPDATE: ${{ secrets.PRIVATE_TOKEN }}"
    )

    assert_includes policy_errors("validate.yml" => invalid),
                    "validate.yml: secret references are forbidden"
  end

  def test_rejects_protected_artifact_actions
    invalid = workflow.sub(
      "      - name: Check Ruby syntax",
      "      - uses: actions/upload-artifact@#{"a" * 40}\n      - name: Check Ruby syntax"
    )

    assert_includes policy_errors("validate.yml" => invalid),
                    "validate.yml: workflow artifact transfer is forbidden"
  end

  def test_validation_triggers_are_closed_and_read_only
    source = workflow
    trigger = source.match(/^on:\n(?<body>.*?)^permissions:/m)["body"]
    assert_match(/^  pull_request:\s*$/, trigger)
    assert_match(/^  push:\n    branches:\n      - main\s*$/, trigger)
    assert_match(/^  workflow_dispatch:\s*$/, trigger)
    refute_match(/^  (?:pull_request_target|schedule|repository_dispatch):/, trigger)
    refute_match(/^\s+(?:contents|pull-requests|actions|checks):\s+write\s*$/, source)
    refute_match(/^\s+packages:\s+(?:read|write)\s*$/, source)
    refute_match(/git\s+push|gh\s+(?:release|pr\s+(?:create|merge))|brew\s+pr-upload/, source)
  end

  def test_manual_public_smoke_is_anonymous_and_exact
    smoke = job_sections(workflow).fetch("public-tap-smoke")
    assert_includes smoke, "github.event_name == 'workflow_dispatch'"
    assert_includes smoke, "github.ref == 'refs/heads/main'"
    assert_includes smoke, "github.event.repository.visibility == 'public'"
    refute_includes smoke, "actions/checkout@"
    assert_includes smoke, "https://api.github.com/repos/zoe-llc/homebrew-crewcli"
    assert_includes smoke, ".id == 1414534332"
    assert_includes smoke, 'test "$observed_sha" = "$GITHUB_SHA"'
    assert_includes smoke, "git clone --no-tags -c credential.helper="
    assert_includes smoke, 'git -C "$clone_root" checkout --detach "$GITHUB_SHA"'
    assert_includes smoke, "brew tap zoe-llc/crewcli"
    assert_includes smoke, "Digest::SHA256.file"
    assert_includes smoke, "env -u GH_TOKEN -u GITHUB_TOKEN -u HOMEBREW_GITHUB_API_TOKEN"
    assert_includes smoke, "git config --global --unset-all http.https://github.com/.extraheader"
    assert_includes smoke, 'test -z "$(git config --global --get-all http.https://github.com/.extraheader || true)"'
    assert_includes smoke, 'token: ""'
    assert_includes smoke, 'brew-gh-api-token: ""'
    refute_match(/secrets\.|Authorization:/, smoke)
  end

  def test_private_phase_zero_validation_uses_only_the_read_only_repository_token
    validation = job_sections(workflow).fetch("validate")
    setup_homebrew = validation.match(
      /uses: Homebrew\/actions\/setup-homebrew@[^\n]+\n(?<body>.*?)(?=\n\s+- name:)/m
    )["body"]

    assert_includes setup_homebrew, 'token: ${{ github.token }}'
    assert_includes setup_homebrew, 'brew-gh-api-token: ""'
    refute_match(/secrets\./, setup_homebrew)
  end

  def test_remote_actions_are_pinned_and_checkout_credentials_do_not_persist
    @workflows.each do |name, source|
      remote_uses = source.scan(/^\s*-?\s*uses:\s*([^\s#]+)/).flatten.reject do |value|
        value.start_with?("./")
      end
      remote_uses.each do |value|
        assert_match(%r{\A[^@\s]+@[a-f0-9]{40}\z}, value, "#{name}: #{value}")
      end
      checkout_count = remote_uses.count { |value| value.start_with?("actions/checkout@") }
      assert_equal checkout_count, source.scan(/^\s+persist-credentials: false\s*$/).length, name
      refute_includes source, "persist-credentials: true", name
    end
  end

  private

  def workflow
    @workflows.fetch("validate.yml")
  end

  def workflow_sources(directory)
    Dir.glob(File.join(directory, WORKFLOW_GLOB)).sort.to_h do |path|
      [File.basename(path), File.read(path)]
    end
  end

  def policy_errors(workflows)
    errors = []
    unless workflows.keys.sort == EXPECTED_WORKFLOWS
      errors << "workflow file set must be exactly validate.yml"
    end
    workflows.each do |name, source|
      unless source.match?(/^permissions:\n  contents: read\n\njobs:/)
        errors << "#{name}: top-level permissions must be contents: read only"
      end
      if source.match?(/^\s+packages:\s+(?:read|write)\s*$/)
        errors << "#{name}: packages permission is forbidden"
      end
      if source.match?(/\$\{\{\s*secrets\./)
        errors << "#{name}: secret references are forbidden"
      end
      if source.match?(/actions\/(?:upload|download)-artifact@/)
        errors << "#{name}: workflow artifact transfer is forbidden"
      end
      if source.match?(/^\s*pull_request_target:/)
        errors << "#{name}: pull_request_target is forbidden"
      end
      if source.match?(/^\s+(?:contents|pull-requests|actions|checks):\s+write\s*$/)
        errors << "#{name}: write permissions are forbidden"
      end
      if source.match?(/git\s+push|gh\s+(?:release|pr\s+(?:create|merge))|brew\s+pr-upload/)
        errors << "#{name}: repository mutation is forbidden"
      end
    end
    errors.uniq
  end

  def job_sections(source)
    jobs = source.split(/^jobs:\n/, 2).fetch(1)
    starts = []
    jobs.to_enum(:scan, /^  ([a-zA-Z0-9_-]+):\n/).each do
      match = Regexp.last_match
      starts << [match[1], match.begin(0)]
    end
    starts.each_with_index.to_h do |(name, offset), index|
      finish = starts.fetch(index + 1, [nil, jobs.length])[1]
      [name, jobs[offset...finish]]
    end
  end
end
