defmodule Jev.WireTest do
  use ExUnit.Case, async: true

  alias Jev.Wire

  test "decodes the documented response" do
    assert {:ok, %Wire.Response{model: "jev-1.13.0", answers: answers, usage: usage}} =
             Wire.Response.from_map(Jev.Fixture.body())

    assert %Wire.Answer{type: :choice, choice: "bug", probabilities: %{"bug" => 0.93}} =
             answers["kind"]

    assert %Wire.Answer{type: :score, legend: %{"3" => "Data loss"}} = answers["severity"]
    assert %Wire.Answer{type: :noul, noul: 0.03, probabilities: %{}} = answers["security"]
    assert %Wire.Usage{input_tokens: 812, output_tokens: 0} = usage
  end

  test "usage defaults to zero when omitted or empty" do
    body = Map.delete(Jev.Fixture.body(), "usage")
    assert %Wire.Response{usage: %Wire.Usage{input_tokens: 0}} = Wire.Response.from_map!(body)

    body = Map.put(body, "usage", %{})
    assert %Wire.Response{usage: %Wire.Usage{input_tokens: 0}} = Wire.Response.from_map!(body)
  end

  test "exposes a JSON schema" do
    schema = Wire.Response.schema()
    assert schema["type"] == "object"
    assert "answers" in schema["required"]
  end
end
