defmodule Jev.ConformanceTest do
  @moduledoc """
  Real response bodies from servers we did not write, decoded by the client.

  A stub only proves the client understands what we imagined. These are
  recorded from running servers, one file per implementation, and they are
  what catches a server or a spec drifting away from us. `README.md` in the
  fixture directory says where each came from.
  """
  use ExUnit.Case, async: true

  @questions Jev.questions(
               kind:
                 {"What kind of issue is this?",
                  %{bug: "Something is broken", billing: "Charges or refunds", other: nil}},
               severity:
                 {"How severe is this for the user?",
                  ["Cosmetic", "Workaround exists", "Blocking"]},
               refund: "Does the customer ask for money back?"
             )

  for path <- Path.wildcard("test/fixtures/conformance/*.json") do
    @path path

    test "#{Path.basename(path, ".json")} decodes into a reply" do
      body = @path |> File.read!() |> JSON.decode!()

      assert {:ok, wire} = Jev.Wire.Response.from_map(body)
      reply = Jev.reply(wire, @questions, usd_per_million_input: 0)

      assert reply.kind in [:bug, :billing, :other]
      assert is_number(reply.severity) and reply.severity >= 0 and reply.severity <= 2
      assert is_number(reply.refund) and reply.refund >= 0 and reply.refund <= 1
      assert Map.keys(reply.probabilities.kind) |> Enum.all?(&is_atom/1)
      assert reply.usage.cost == 0
      assert is_binary(reply.model)

      # Whatever the server says, confidence means what Jev says it means.
      assert_in_delta reply.confidence.kind, Jev.confidence(reply.probabilities.kind, 3), 5.0e-4
    end
  end
end
