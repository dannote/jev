# A live smoke test against a self-hosted /v1/systemone server, such as
# jeff, an OpenJev server, or anything else that speaks the wire format.
#
#     JEV_LOCAL_URL=http://localhost:8000 JEV_LOCAL_KEY=devkey mix run examples/local.exs
#
# It checks what a stub cannot: that a server we did not write is understood,
# that a missing confidence is derived, that a named endpoint sends its key
# and bills nothing, and that a rejected key becomes a Jev.Error.

url = System.get_env("JEV_LOCAL_URL") || "http://localhost:8000"
key = System.get_env("JEV_LOCAL_KEY")

Application.put_env(:jev, :endpoints, local: [base_url: url, api_key: key])

:telemetry.attach(
  "smoke",
  [:jev, :request, :stop],
  fn _event, measurements, metadata, _ ->
    usage =
      case measurements do
        %{input_tokens: tokens, cost: cost} -> " tokens=#{tokens} cost=#{cost}"
        _ -> ""
      end

    IO.puts(
      "  telemetry: endpoint=#{inspect(metadata.endpoint)} " <>
        "status=#{inspect(metadata[:status])}#{usage}"
    )
  end,
  nil
)

state = %{
  title: "Charged twice for March",
  body: "We were billed twice and the export button also crashes in Safari. Please refund today."
}

questions = [
  kind:
    {"What kind of issue is this?",
     %{bug: "Something is broken", billing: "Charges or refunds", other: nil}},
  severity: {"How severe is this for the user?", ["Cosmetic", "Workaround exists", "Blocking"]},
  refund: "Does the customer ask for money back?"
]

IO.puts("\nAsking #{url} ...")

case Jev.HTTP.post(state, questions, endpoint: :local) do
  {:ok, reply} ->
    IO.puts("  model:      #{inspect(reply.model)}")

    IO.puts(
      "  kind:       #{inspect(reply.kind)}  confidence #{inspect(reply.confidence[:kind])}"
    )

    IO.puts(
      "  severity:   #{inspect(reply.severity)}  confidence #{inspect(reply.confidence[:severity])}"
    )

    IO.puts("  refund:     #{inspect(reply.refund)}")
    IO.puts("  probabilities: #{inspect(reply.probabilities.kind)}")
    IO.puts("  usage:      #{inspect(reply.usage)}")

    checks = [
      {"choice is one of the criteria atoms", reply.kind in [:bug, :billing, :other]},
      {"score is a number in range",
       is_number(reply.severity) and reply.severity >= 0 and reply.severity <= 2},
      {"noul is a probability",
       is_number(reply.refund) and reply.refund >= 0 and reply.refund <= 1},
      {"confidence present for the choice", is_number(reply.confidence[:kind])},
      {"probabilities keyed by label atoms",
       Map.keys(reply.probabilities.kind) |> Enum.all?(&is_atom/1)},
      {"a named endpoint bills nothing", reply.usage.cost == 0}
    ]

    IO.puts("")
    for {name, ok} <- checks, do: IO.puts("  #{if ok, do: "ok  ", else: "FAIL"} #{name}")
    if Enum.all?(checks, &elem(&1, 1)), do: IO.puts("\nAll checks passed."), else: System.halt(1)

  {:error, error} ->
    IO.puts("  failed: #{Exception.message(error)}")
    System.halt(1)
end

if key do
  IO.puts("\nWith a rejected key ...")

  case Jev.HTTP.post(state, [refund: "Money back?"],
         endpoint: :local,
         api_key: "wrong",
         max_retries: 0
       ) do
    {:error, %Jev.Error{status: status} = error} ->
      IO.puts("  ok   #{status}: #{Exception.message(error)}")

    other ->
      IO.puts("  FAIL expected a Jev.Error, got #{inspect(other)}")
      System.halt(1)
  end
end
