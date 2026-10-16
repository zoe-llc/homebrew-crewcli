# frozen_string_literal: true

require "minitest/autorun"
require "time"

require_relative "../scripts/verify_activation_window"

class VerifyActivationWindowTest < Minitest::Test
  VERSION = "0.1.0"
  SOURCE_SHA = "1" * 40
  AUTHORIZATION_SHA = "2" * 40
  EVIDENCE_SHA = "3" * 40
  GATE_IDS = %w[
    distribution-config-release-workflow
    release-authorization-boundary
    manifest-reader-app
    private-tap-access
    private-ghcr-access
    license-sbom-redistribution
    bottle-build-runners
    wsl2-consumer-runner
    dedicated-canary-target
    retention-rollback-activation-window
  ].freeze

  def test_accepts_the_exact_open_pass_window
    result = CliDistribution::ActivationWindow.verify!(
      evidence,
      expected: expected,
      ancestry: ancestry,
      now: Time.iso8601("2026-10-12T12:00:00Z")
    )

    assert_equal "crewcli.homebrew-activation-authorization/v1", result.fetch("schema")
    assert_equal VERSION, result.fetch("version")
    assert_equal SOURCE_SHA, result.fetch("sourceSha")
    assert_equal AUTHORIZATION_SHA, result.fetch("authorizationSha")
    assert_equal "stable-unavailable", result.fetch("rollbackPoint")
  end

  def test_rejects_closed_window_actor_identity_and_release_drift
    invalid = [
      [evidence, expected, Time.iso8601("2026-10-13T00:00:00Z")],
      [evidence, expected.merge("executor" => "github:other"), Time.iso8601("2026-10-12T12:00:00Z")],
      [evidence.merge("version" => "0.1.1"), expected, Time.iso8601("2026-10-12T12:00:00Z")],
      [evidence.merge("sourceSha" => "a" * 40), expected, Time.iso8601("2026-10-12T12:00:00Z")]
    ]

    invalid.each do |value, contract, now|
      assert_raises(CliDistribution::ActivationWindowError) do
        CliDistribution::ActivationWindow.verify!(value, expected: contract, ancestry: ancestry, now: now)
      end
    end
  end

  def test_rejects_missing_duplicate_non_pass_and_malformed_gates
    gates = evidence.fetch("gates")
    invalid = [
      evidence.merge("gates" => gates.drop(1)),
      evidence.merge("gates" => [*gates.drop(1), gates.first]),
      evidence.merge("gates" => gates.map.with_index { |gate, index| index.zero? ? gate.merge("result" => "FAIL") : gate }),
      evidence.merge("gates" => gates.map.with_index { |gate, index| index.zero? ? gate.merge("evidenceUrl" => "https://example.com/gate") : gate })
    ]

    invalid.each do |value|
      assert_raises(CliDistribution::ActivationWindowError) do
        CliDistribution::ActivationWindow.verify!(
          value,
          expected: expected,
          ancestry: ancestry,
          now: Time.iso8601("2026-10-12T12:00:00Z")
        )
      end
    end
  end

  def test_rejects_unknown_or_sensitive_fields_without_echoing_values
    value = evidence.merge("token" => "secret-sentinel")
    error = assert_raises(CliDistribution::ActivationWindowError) do
      CliDistribution::ActivationWindow.verify!(
        value,
        expected: expected,
        ancestry: ancestry,
        now: Time.iso8601("2026-10-12T12:00:00Z")
      )
    end
    refute_match(/secret-sentinel/, error.message)
  end

  def test_rejects_authorization_not_on_develop_or_source_not_in_authorization_history
    invalid = [
      ancestry.merge(
        "authorizationOnDevelop" => ancestry.fetch("authorizationOnDevelop").merge("mergeBaseSha" => "a" * 40)
      ),
      ancestry.merge(
        "sourceToAuthorization" => ancestry.fetch("sourceToAuthorization").merge("status" => "diverged")
      )
    ]

    invalid.each do |value|
      assert_raises(CliDistribution::ActivationWindowError) do
        CliDistribution::ActivationWindow.verify!(
          evidence,
          expected: expected,
          ancestry: value,
          now: Time.iso8601("2026-10-12T12:00:00Z")
        )
      end
    end
  end

  private

  def expected
    {
      "version" => VERSION,
      "sourceSha" => SOURCE_SHA,
      "authorizationSha" => AUTHORIZATION_SHA,
      "executor" => "github:kaz-toc"
    }
  end

  def evidence
    {
      "schema" => "crewcli.internal-activation-window/v2",
      "decision" => "PASS",
      "version" => VERSION,
      "sourceSha" => SOURCE_SHA,
      "gates" => GATE_IDS.map do |id|
        {
          "id" => id,
          "result" => "PASS",
          "evidenceUrl" => "https://github.com/zoe-llc/crewent/blob/#{EVIDENCE_SHA}/docs/verification/gate.md"
        }
      end,
      "activationWindow" => {
        "startsAt" => "2026-10-12T00:00:00Z",
        "endsAt" => "2026-10-12T23:59:59Z"
      },
      "actors" => {
        "executor" => "github:kaz-toc",
        "authorizationOwner" => "github:kaz-toc",
        "releaseOwner" => "github:kaz-toc",
        "rollbackOwner" => "github:kaz-toc"
      },
      "authorization" => {
        "mode" => "repository-record",
        "independentReviewerRequired" => false
      },
      "rollback" => { "point" => "stable-unavailable" }
    }
  end


  def ancestry
    {
      "authorizationOnDevelop" => {
        "baseSha" => AUTHORIZATION_SHA,
        "head" => "develop",
        "mergeBaseSha" => AUTHORIZATION_SHA,
        "status" => "ahead"
      },
      "sourceToAuthorization" => {
        "baseSha" => SOURCE_SHA,
        "head" => AUTHORIZATION_SHA,
        "mergeBaseSha" => SOURCE_SHA,
        "status" => "ahead"
      }
    }
  end
end
