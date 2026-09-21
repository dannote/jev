defmodule Jev.APIStub do
  @moduledoc false
  # Plug responses shaped like the TypeSafe API, for use with Req.Test.
  #
  # Bodies are built from Jev.Wire structs and dumped, so a stub can only
  # produce what the client's own codecs accept.

  import Plug.Conn

  alias Jev.Wire

  @doc "Sends `data` as a JSON response with `status`."
  def json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(data))
  end

  @doc "Reads and decodes the JSON request body."
  def body(conn) do
    {:ok, raw, conn} = read_body(conn)
    {JSON.decode!(raw), conn}
  end

  @doc """
  A wire-shaped success body for the triage questions.

  `overrides` are merged into the answers map as raw wire maps, so a test can
  send exactly what a server would.
  """
  def triage_body(overrides \\ %{}) do
    answers = %{
      "kind" => %Wire.Answer{
        type: :choice,
        choice: "bug",
        confidence: 0.91,
        probabilities: %{"bug" => 0.93, "feature" => 0.04, "other" => 0.03}
      },
      "severity" => %Wire.Answer{
        type: :score,
        score: 2.4,
        confidence: 0.62,
        legend: %{"0" => "Cosmetic", "1" => "Workaround", "2" => "Blocks", "3" => "Data loss"},
        probabilities: %{"0" => 0.1, "1" => 0.1, "2" => 0.2, "3" => 0.6}
      },
      "security" => %Wire.Answer{type: :noul, noul: 0.03}
    }

    %Wire.Response{
      model: "jev-1.13.0",
      answers: answers,
      usage: %Wire.Usage{input_tokens: 812, output_tokens: 0}
    }
    |> dump()
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

  # JSONCodec.dump/1 keeps nil fields; the API omits them.
  defp dump(struct) do
    struct
    |> JSONCodec.dump()
    |> prune()
  end

  defp prune(%{} = map),
    do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new(fn {k, v} -> {k, prune(v)} end)

  defp prune(other), do: other
end
