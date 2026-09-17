defmodule JevTest do
  use ExUnit.Case
  doctest Jev

  test "greets the world" do
    assert Jev.hello() == :world
  end
end
