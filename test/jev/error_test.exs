defmodule Jev.ErrorTest do
  use ExUnit.Case, async: true

  test "message includes the status, a description, and the request id" do
    error = %Jev.Error{
      status: 422,
      body: %{"error" => %{"message" => "bad criteria"}},
      request_id: "abc"
    }

    assert Exception.message(error) == "TypeSafe responded 422: bad criteria (request abc)"
  end

  test "message handles text, empty, and unknown bodies" do
    assert Exception.message(%Jev.Error{status: 502, body: "gateway"}) ==
             "TypeSafe responded 502: gateway"

    assert Exception.message(%Jev.Error{status: 529, body: nil}) ==
             "TypeSafe responded 529: (no body)"

    assert Exception.message(%Jev.Error{status: 500, body: %{"x" => 1}}) ==
             ~s(TypeSafe responded 500: {"x":1})
  end
end
