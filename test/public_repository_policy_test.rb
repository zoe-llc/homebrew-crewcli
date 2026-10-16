# frozen_string_literal: true

require "minitest/autorun"

class PublicRepositoryPolicyTest < Minitest::Test
  WORKFLOW_DIRECTORY = File.expand_path("../.github/workflows", __dir__)
  MUTATION_WORKFLOWS = %w[bottle.yml canary.yml import-manifest.yml promote.yml].freeze

  def setup
    @workflows = Dir.glob(File.join(WORKFLOW_DIRECTORY, "*.yml")).sort.to_h do |path|
      [File.basename(path), File.read(path)]
    end
  end

  def test_forbids_pull_request_target_in_every_workflow
    @workflows.each do |name, source|
      refute_match(/^\s*pull_request_target:/, source, name)
    end
  end

  def test_mutation_workflows_are_manual_main_only
    MUTATION_WORKFLOWS.each do |name|
      source = @workflows.fetch(name)
      trigger = source.match(/^on:\n(?<body>.*?)^permissions:/m)["body"]
      assert_match(/^  workflow_dispatch:/, trigger, name)
      refute_match(/^  (?:pull_request|push):/, trigger, name)

      job_sections(source).each do |job, section|
        assert_match(
          /^    if: .*github\.ref == 'refs\/heads\/main'/,
          section,
          "#{name}:#{job} must guard exact main"
        )
      end
    end
  end

  def test_pull_request_validation_is_read_only_and_secret_free
    source = @workflows.fetch("validate.yml")
    assert_match(/^  pull_request:/, source)
    assert_match(/^permissions:\n  contents: read\n\njobs:/, source)
    refute_match(/^\s+(?:packages|pull-requests|actions):\s+write\s*$/, source)
    refute_match(
      /CLI_DISTRIBUTION_READER_APP_PRIVATE_KEY|GHCR_READ_|CLI_GHCR_READ_|secrets\./,
      source
    )
    assert_includes source, "ruby -Itest test/public_repository_policy_test.rb"
  end

  def test_write_permissions_are_limited_to_two_manual_jobs
    observed = @workflows.flat_map do |name, source|
      job_sections(source).flat_map do |job, section|
        section.scan(/^      ([a-z-]+): write\s*$/).flatten.map do |permission|
          [name, job, permission]
        end
      end
    end
    assert_equal(
      [
        ["bottle.yml", "publish", "packages"],
        ["promote.yml", "promote", "actions"],
        ["promote.yml", "promote", "contents"],
        ["promote.yml", "promote", "pull-requests"]
      ],
      observed.sort
    )
  end

  def test_remote_actions_are_pinned_and_checkout_credentials_are_not_persisted
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

  def test_manual_public_tap_smoke_is_anonymous_and_exact
    source = @workflows.fetch("validate.yml")
    smoke = job_sections(source).fetch("public-tap-smoke")
    assert_includes smoke, "github.event_name == 'workflow_dispatch'"
    assert_includes smoke, "github.ref == 'refs/heads/main'"
    assert_includes smoke, "github.event.repository.visibility == 'public'"
    assert_includes smoke, "https://api.github.com/repos/zoe-llc/homebrew-crewcli"
    assert_includes smoke, ".id == 1414534332"
    assert_includes smoke, 'test "$observed_sha" = "$GITHUB_SHA"'
    assert_includes smoke, "brew tap zoe-llc/crewcli"
    assert_includes smoke, "Digest::SHA256.file"
    assert_includes smoke, "if: always()"
    refute_match(/secrets\.|Authorization:|http\.extraheader/, smoke)
  end

  private

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
