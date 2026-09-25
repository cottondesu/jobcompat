require_relative "../test_helper"

class ContractTest < Minitest::Test
  def contract(minimum, maximum, reason = nil)
    Jobcompat::Contract.new("ExportJob", minimum, maximum, "positional", "perform", reason, [], [], [])
  end

  def test_membership_boundaries
    finite = contract(1, 3)
    refute finite.accepts?(0)
    assert finite.accepts?(1)
    assert finite.accepts?(2)
    assert finite.accepts?(3)
    refute finite.accepts?(4)
    variadic = contract(2, nil)
    refute variadic.accepts?(1)
    assert variadic.accepts?(1_000_000)
    refute contract(nil, nil, "keyword_parameters").accepts?(1)
  end

  def test_interval_inclusion
    assert contract(0, 3).superset_of?(contract(1, 2))
    assert contract(0, nil).superset_of?(contract(1, nil))
    refute contract(1, 3).superset_of?(contract(0, 3))
    refute contract(0, 3).superset_of?(contract(0, nil))
    refute contract(1, nil).superset_of?(contract(0, nil))
    assert contract(1, nil).superset_of?(contract(1, 100))
  end
end
