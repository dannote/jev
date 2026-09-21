defmodule Jev.Fixture do
  @moduledoc false
  # The triage example as test data: its questions, a reply, and the wire body.

  @doc "The triage questions in shorthand."
  def questions do
    [
      kind: {"What kind of issue?", %{bug: "Broken", feature: "New behavior", other: nil}},
      severity: {"How severe?", ["Cosmetic", "Workaround", "Blocks", "Data loss"]},
      security: "Is this a vulnerability?"
    ]
  end

  @doc "A confident bug report, reply-shaped, for `Jev.Test.respond/2`."
  def reply do
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
  end

  @doc """
  The wire body of `reply/0`, with `overrides` merged into its answers as raw
  wire maps, so a test can send exactly what a server would.
  """
  def body(overrides \\ %{}) do
    reply()
    |> Jev.Test.body(questions())
    |> update_in(["answers"], &Map.merge(&1, overrides))
  end
end
