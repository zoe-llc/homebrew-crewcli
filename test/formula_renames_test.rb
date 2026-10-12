# frozen_string_literal: true

require "json"
require "minitest/autorun"

class FormulaRenamesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_crewcli_is_renamed_to_existing_crewent_formula
    renames = JSON.parse(File.read(File.join(ROOT, "formula_renames.json")))

    assert_equal({ "crewcli" => "crewent" }, renames)
    assert File.file?(File.join(ROOT, "Formula/crewent.rb"))
    refute File.exist?(File.join(ROOT, "Formula/crewcli.rb"))
  end
end
