# frozen_string_literal: true

require "minitest/autorun"

class CompatibilityMetadataTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_formula_surface_has_no_compatibility_metadata
    refute File.exist?(File.join(ROOT, "formula_renames.json"))
    assert_equal [File.join(ROOT, "Formula", "crewent.rb")],
                 Dir.glob(File.join(ROOT, "Formula", "*.rb")).sort
  end
end
