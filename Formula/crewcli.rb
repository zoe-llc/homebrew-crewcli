# frozen_string_literal: true

require "json"

# Internal CLI distribution Formula.
class Crewcli < Formula
  desc "Internal CLI distribution"
  homepage "https://github.com/zoe-llc/crewcli"
  url "https://github.com/zoe-llc/crewcli/releases/download/cli-v0.1.0/crewcli-cli-0.1.0.tgz"
  sha256 "c7c5c1d70c5dec4416ab6158afd0b223ef40c29b1dc1f97ed9428b94d4cadb1c"
  license :cannot_represent

  depends_on "node@22"

  def install
    if ENV["HOMEBREW_CLI_DISTRIBUTION_BOTTLE_BUILD"] != "1"
      odie "Prebuilt bottle required; consumer source fallback is disabled"
    end

    package_root = buildpath/"package"
    odie "npm package root is missing" unless package_root.directory?
    libexec.install package_root.children

    metadata = JSON.parse((libexec/"package.json").read)
    bin_map = metadata.fetch("bin")
    expected_commands = ["crewcli"]
    if bin_map.keys.sort != expected_commands.sort
      odie "package command set does not match the release manifest"
    end

    expected_commands.each do |command|
      relative = bin_map.fetch(command)
      parts = relative.is_a?(String) ? relative.delete_prefix("./").split("/") : []
      safe_parts = parts.any? && parts.none? do |part|
        part.empty? || part == "." || part == ".." || !part.match?(/\A[A-Za-z0-9_.-]+\z/)
      end
      odie "package command path is unsafe" unless safe_parts
      entry = libexec.join(*parts).cleanpath
      odie "package command escapes libexec" unless entry.to_s.start_with?("#{libexec}/")
      (bin/command).write_env_script entry, PATH: formula_opt_bin("node@22")
    end
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/crewcli --version")
    assert_match "Usage:", shell_output("#{bin}/crewcli --help")
  end
end
