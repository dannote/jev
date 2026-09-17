defmodule Jev.Triage do
  @moduledoc false
  # The README example, kept as code so the docs stay honest.

  use Jev.Server

  @impl true
  def init(_arg), do: {:ok, %{}}

  @impl true
  def handle_call({:labels, issue}, from, s) do
    {:reply, {from, issue, Jev.APIStub.triage_questions()}, s}
  end

  # Clause order is the routing.
  @impl true
  def handle_answer(%{security: p}, from, s) when p > 0.5, do: done(from, [:security], s)

  def handle_answer(%{kind: :bug, severity: sev, confidence: %{kind: c}}, from, s)
      when c > 0.85 and sev >= 2,
      do: done(from, [:bug, :"priority:high"], s)

  def handle_answer(%{kind: k, confidence: %{kind: c}}, from, s) when c > 0.6,
    do: done(from, [k], s)

  def handle_answer(%{kind: k}, from, s), do: done(from, [k, :"needs-triage"], s)
  def handle_answer({:error, reason}, from, s), do: done(from, {:error, reason}, s)

  defp done(from, result, s) do
    GenServer.reply(from, result)
    {:noreply, s}
  end
end
