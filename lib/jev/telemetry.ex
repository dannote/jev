defmodule Jev.Telemetry do
  @moduledoc """
  The telemetry every backend emits.

  `span/4` wraps one request in `[:jev, :request, :start | :stop | :exception]`
  and fires `[:jev, :answer]` once per answered question. `Jev.HTTP` uses it,
  and a `Jev.Backend` of your own should too, so a calibration histogram or a
  cost sum sees local models and Jev alike.

  | Event | Measurements | Metadata |
  | --- | --- | --- |
  | `[:jev, :request, :start]` | `system_time` | `backend`, `endpoint`, `model`, `questions`, `state_hash`, `tag` |
  | `[:jev, :request, :stop]` | `duration`, `input_tokens`, `output_tokens`, `cost` | plus `status`, `request_id`, `confidence` |
  | `[:jev, :request, :exception]` | `duration` | plus `kind`, `reason`, `stacktrace` |
  | `[:jev, :answer]` | `confidence`, `probability` | `name`, `type`, `answer`, plus the start metadata |

  `questions` is a map of question name to type. The state is never in
  metadata, only its hash.
  """

  @typedoc "What the function given to `span/4` returns."
  @type result ::
          {:ok, Jev.reply()} | {:ok, Jev.reply(), stop_metadata :: map()} | {:error, term()}

  @doc """
  Runs `fun` as one request, emitting the events above.

  `metadata` is what the backend knows before the call: `backend`, `tag`, and
  for `Jev.HTTP` `endpoint` and `model`. `questions` and `state_hash` are added.
  `fun` returns `{:ok, reply}`, `{:ok, reply, stop_metadata}` to add to the
  stop event, or `{:error, reason}`. A `Jev.Error` reason contributes its
  `status` and `request_id`; any other reason is put under `error`.

  Returns `{:ok, reply}` or `{:error, reason}`.
  """
  @spec span(Jev.entry(), Jev.questions(), map(), (-> result())) ::
          {:ok, Jev.reply()} | {:error, term()}
  def span(state, questions, metadata, fun) do
    metadata =
      Map.merge(metadata, %{
        questions: Map.new(questions, fn {name, %{type: type}} -> {name, type} end),
        state_hash: :erlang.phash2(state)
      })

    :telemetry.span([:jev, :request], metadata, fn ->
      case fun.() do
        {:ok, reply} -> stop({:ok, reply}, reply, %{}, metadata)
        {:ok, reply, stop_metadata} -> stop({:ok, reply}, reply, stop_metadata, metadata)
        {:error, reason} = error -> {error, %{}, Map.merge(metadata, failure(reason))}
      end
    end)
  end

  defp stop(result, reply, stop_metadata, metadata) do
    emit_answers(reply, metadata)
    stop_metadata = Map.put(stop_metadata, :confidence, reply.confidence)
    {result, reply.usage, Map.merge(metadata, stop_metadata)}
  end

  defp failure(%Jev.Error{status: status, request_id: id}), do: %{status: status, request_id: id}
  defp failure(reason), do: %{error: reason}

  # One event per answered question; a server may leave a question out.
  defp emit_answers(reply, %{questions: questions} = metadata) do
    metadata = Map.delete(metadata, :questions)

    for {name, type} <- questions, is_map_key(reply, name) do
      measurements = answer_measurements(type, name, reply)
      metadata = Map.merge(metadata, %{name: name, type: type, answer: reply[name]})
      :telemetry.execute([:jev, :answer], measurements, metadata)
    end

    :ok
  end

  defp answer_measurements(:noul, name, reply), do: %{probability: reply[name]}

  defp answer_measurements(_type, name, reply) do
    top = reply.probabilities[name] |> Map.values() |> Enum.max(&>=/2, fn -> nil end)
    %{confidence: reply.confidence[name], probability: top}
  end
end
