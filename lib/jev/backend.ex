defmodule Jev.Backend do
  @moduledoc """
  What answers the questions: a behaviour with one callback.

  `Jev.HTTP` is the backend that speaks to TypeSafe and compatible servers.
  An in-process model, a cache, or a fake for tests is another module with
  the same shape:

      defmodule Canned do
        @behaviour Jev.Backend

        @impl true
        def post(state, questions, opts) do
          Jev.Telemetry.span(state, questions, %{backend: __MODULE__, tag: opts[:tag]}, fn ->
            {:ok, Jev.reply(Jev.Test.body([kind: :bug], questions), questions)}
          end)
        end
      end

  A `Jev.Server` picks the backend per request or from configuration:

      {:reply, {tag, state, [kind: @kinds], [backend: Canned]}, s}

      config :jev, backend: Canned

  The callback receives the state, the questions as `Jev.questions/1` returns
  them, and the request options with `tag` among them. It returns
  `{:ok, reply}` with the map `Jev.reply/3` builds, or `{:error, reason}`.
  Wrapping the work in `Jev.Telemetry.span/4` is what makes the cost and
  calibration telemetry, and the dashboards on it, work for every backend.
  """

  @callback post(state :: Jev.entry(), questions :: Jev.questions(), opts :: keyword()) ::
              {:ok, Jev.reply()} | {:error, term()}
end
