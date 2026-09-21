defmodule Jev.Canned do
  @moduledoc false
  # A Jev.Backend that answers from a table, keyed by state. Tests use it to
  # check that servers route to the backend they were given.

  @behaviour Jev.Backend

  @impl true
  def post(state, questions, opts) do
    Jev.Telemetry.span(state, questions, %{backend: __MODULE__, tag: opts[:tag]}, fn ->
      case Keyword.fetch(opts, :answers) do
        {:ok, answers} -> {:ok, Jev.reply(Jev.Test.body(answers, questions), questions)}
        :error -> {:error, :no_answers}
      end
    end)
  end
end
