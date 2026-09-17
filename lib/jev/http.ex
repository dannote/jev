defmodule Jev.HTTP do
  @moduledoc """
  The transport: one POST to `/v1/systemone` per call.

  This is the seam between the pure modules and the network. `Jev.Server` calls
  it from a task; scripts and evaluation harnesses call it directly.

  ## Configuration

      config :jev,
        api_key: System.get_env("TYPESAFE_API_KEY"),  # or the TYPESAFE_API_KEY env var
        base_url: "https://api.typesafe.ai",
        model: "jev-latest",
        max_retries: 3,
        receive_timeout: 30_000,
        usd_per_million_input: 0.042,
        req_options: []                                 # merged into Req.new/1, e.g. a test plug

  Every option except `usd_per_million_input` and `req_options` can also be
  passed per call. Requests that fail with 429 or 529 are retried with backoff,
  honouring `Retry-After`, as the API documentation asks.

  ## Telemetry

  `[:jev, :request, :start | :stop | :exception]` wrap each call with
  `:telemetry.span/3`. Stop measurements carry `input_tokens`, `output_tokens`,
  and `cost`; metadata carries `model`, `questions` (name to type), `state_hash`,
  `tag`, `status`, `request_id`, and `confidence`.

  `[:jev, :answer]` fires once per question after a successful call with
  `confidence` and `probability` measurements and `name`, `type`, `answer`,
  `model`, `state_hash`, and `tag` metadata. A histogram of `confidence` by
  `name` is a calibration monitor.

  The state itself is never put in metadata, only its hash.
  """

  @default_base_url "https://api.typesafe.ai"
  @default_model "jev-latest"

  @type option ::
          {:model, String.t()}
          | {:api_key, String.t()}
          | {:base_url, String.t()}
          | {:max_retries, non_neg_integer()}
          | {:receive_timeout, timeout()}
          | {:tag, term()}

  @doc """
  Evaluates `questions` against `state`.

  Returns `{:ok, reply}` with the map described in `Jev`, or `{:error, error}`
  where `error` is a `Jev.Error` for a non-2xx response or the transport
  exception. Raises `ArgumentError` for malformed questions or a missing API key.
  """
  @spec post(Jev.entry(), keyword(Jev.shorthand()) | %{atom() => Jev.shorthand()}, [option()]) ::
          {:ok, Jev.reply()} | {:error, Jev.Error.t() | Exception.t()}
  def post(state, questions, opts \\ []) do
    questions = Jev.questions(questions)
    model = opts[:model] || config(:model, @default_model)

    metadata = %{
      model: model,
      questions: Map.new(questions, fn {name, %{type: type}} -> {name, type} end),
      state_hash: :erlang.phash2(state),
      tag: opts[:tag]
    }

    :telemetry.span([:jev, :request], metadata, fn ->
      case request(state, questions, model, opts) do
        {:ok, reply, request_id} ->
          emit_answers(reply, metadata)
          stop = %{status: 200, request_id: request_id, confidence: reply.confidence}
          {{:ok, reply}, reply.usage, Map.merge(metadata, stop)}

        {:error, %Jev.Error{status: status, request_id: id}} = error ->
          {error, %{}, Map.merge(metadata, %{status: status, request_id: id})}

        {:error, exception} = error ->
          {error, %{}, Map.put(metadata, :error, exception)}
      end
    end)
  end

  defp request(state, questions, model, opts) do
    body = JSON.encode!(%{model: model, state: state, questions: questions})

    request =
      Req.new(
        [
          base_url: opts[:base_url] || config(:base_url, @default_base_url),
          auth: {:bearer, api_key(opts)},
          headers: [accept: "application/json", content_type: "application/json"],
          decode_body: false,
          retry: &retry?/2,
          max_retries: opts[:max_retries] || config(:max_retries, 3),
          receive_timeout: opts[:receive_timeout] || config(:receive_timeout, 30_000)
        ] ++ config(:req_options, [])
      )

    case Req.post(request, url: "/v1/systemone", body: body) do
      {:ok, %Req.Response{status: 200, body: body} = response} ->
        {:ok, Jev.reply(JSON.decode!(body), questions), request_id(response)}

      {:ok, %Req.Response{status: status, body: body} = response} ->
        {:error, %Jev.Error{status: status, body: decode(body), request_id: request_id(response)}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp retry?(_request, %Req.Response{status: status}), do: status in [429, 529]
  defp retry?(_request, _exception), do: true

  defp api_key(opts) do
    opts[:api_key] || config(:api_key) || System.get_env("TYPESAFE_API_KEY") ||
      raise ArgumentError,
            "pass :api_key, set config :jev, api_key: ..., or set TYPESAFE_API_KEY"
  end

  defp config(key, default \\ nil), do: Application.get_env(:jev, key, default)

  defp request_id(response) do
    response |> Req.Response.get_header("x-typesafe-request-id") |> List.first("")
  end

  defp decode(""), do: nil

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, json} -> json
      {:error, _} -> body
    end
  end

  defp emit_answers(reply, %{questions: questions} = metadata) do
    metadata = Map.delete(metadata, :questions)

    Enum.each(questions, fn {name, type} ->
      measurements = answer_measurements(type, name, reply)
      metadata = Map.merge(metadata, %{name: name, type: type, answer: reply[name]})
      :telemetry.execute([:jev, :answer], measurements, metadata)
    end)
  end

  defp answer_measurements(:noul, name, reply), do: %{probability: reply[name]}

  defp answer_measurements(_type, name, reply) do
    top = reply.probabilities[name] |> Map.values() |> Enum.max(&>=/2, fn -> nil end)
    %{confidence: reply.confidence[name], probability: top}
  end
end
