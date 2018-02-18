defmodule PassingAndFailingTest do
  use ExUnit.Case

  test "fails", do: assert(1 == 2)
  test "passes", do: assert(1 == 1)
end
