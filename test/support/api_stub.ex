defmodule Jev.APIStub do
  @moduledoc false
  # The triage fixture, built with Jev.Test so the tests exercise it.

  @doc "Sends `data` as a JSON response with `status`."
  def json(conn, status, data) do
    conn
    |> Plug.Conn.put_status(status)
    |> Req.Test.json(data)
  end

  @doc "Reads and decodes the JSON request body."
  def body(conn), do: Jev.Test.request(conn)

  @doc """
  A wire-shaped success body for the triage questions.

  `overrides` are merged into the answers map as raw wire maps, so a test can
  send exactly what a server would.
  """
  def triage_body(overrides \\ %{}) do
    [
      kind: :bug,
      severity: 2.4,
      security: 0.03,
      confidence: %{kind: 0.91, severity: 0.62},
      probabilities: %{
        kind: %{bug: 0.93, feature: 0.04, other: 0.03},
        severity: %{0 => 0.1, 1 => 0.1, 2 => 0.2, 3 => 0.6}
      },
      model: "jev-1.13.0",
      usage: %{input_tokens: 812}
    ]
    |> Jev.Test.body(triage_questions())
    |> update_in(["answers"], &Map.merge(&1, overrides))
  end

  @doc "The triage questions in shorthand."
  def triage_questions do
    [
      kind: {"What kind of issue?", %{bug: "Broken", feature: "New behavior", other: nil}},
      severity: {"How severe?", ["Cosmetic", "Workaround", "Blocks", "Data loss"]},
      security: "Is this a vulnerability?"
    ]
  end
end
