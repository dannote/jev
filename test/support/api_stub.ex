defmodule Jev.APIStub do
  @moduledoc false
  # Plug responses shaped like the TypeSafe API, for use with Req.Test.

  import Plug.Conn

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

  @doc "A wire-shaped success body for the triage questions."
  def triage_body(overrides \\ %{}) do
    answers =
      Map.merge(
        %{
          "kind" => %{
            "type" => "choice",
            "choice" => "bug",
            "confidence" => 0.91,
            "probabilities" => %{"bug" => 0.93, "feature" => 0.04, "other" => 0.03}
          },
          "severity" => %{
            "type" => "score",
            "score" => 2.4,
            "confidence" => 0.62,
            "legend" => %{
              "0" => "Cosmetic",
              "1" => "Workaround",
              "2" => "Blocks",
              "3" => "Data loss"
            },
            "probabilities" => %{"0" => 0.1, "1" => 0.1, "2" => 0.2, "3" => 0.6}
          },
          "security" => %{"type" => "noul", "noul" => 0.03}
        },
        overrides
      )

    %{
      "model" => "jev-1.13.0",
      "answers" => answers,
      "usage" => %{"input_tokens" => 812, "output_tokens" => 0}
    }
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
