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

  ## Endpoints

  The wire format is spoken by more than TypeSafe: self-hosted decision models
  such as Laya, kev, decider, and jeff serve the same `/v1/systemone`. Name
  them under `endpoints` and pick one per call with `endpoint:`:

      config :jev,
        endpoints: [
          laya: [base_url: "http://localhost:8000"],
          jeff: [base_url: "https://jeff.internal", api_key: "...", model: "gliformer-large"]
        ]

      Jev.HTTP.post(state, questions, endpoint: :laya)

  The top-level configuration is the `:typesafe` endpoint, which is the
  default; `config :jev, endpoint: :laya` changes the default. A named
  endpoint takes `base_url` (required), `api_key`, `model`, and
  `usd_per_million_input`, plus `max_retries`, `receive_timeout`, and
  `req_options`. It never inherits the TypeSafe key or price: without an
  `api_key` no `Authorization` header is sent, and the price defaults to zero.
  Transport settings are inherited. See `endpoint/1` for the resolved result.

  ## Telemetry

  `[:jev, :request, :start | :stop | :exception]` wrap each call with
  `:telemetry.span/3`. Stop measurements carry `input_tokens`, `output_tokens`,
  and `cost`; metadata carries `endpoint`, `model`, `questions` (name to type),
  `state_hash`, `tag`, `status`, `request_id`, and `confidence`.

  `[:jev, :answer]` fires once per question after a successful call with
  `confidence` and `probability` measurements and `name`, `type`, `answer`,
  `endpoint`, `model`, `state_hash`, and `tag` metadata. A histogram of
  `confidence` by `name` is a calibration monitor.

  The state itself is never put in metadata, only its hash.
  """

  @default_base_url "https://api.typesafe.ai"
  @default_model "jev-latest"
  @default_price 0.042
  @overridable [:base_url, :api_key, :model, :max_retries, :receive_timeout]

  @type option ::
          {:endpoint, atom()}
          | {:model, String.t()}
          | {:api_key, String.t() | nil}
          | {:base_url, String.t()}
          | {:max_retries, non_neg_integer()}
          | {:receive_timeout, timeout()}
          | {:tag, term()}

  @typedoc "A resolved endpoint, as returned by `endpoint/1`."
  @type endpoint :: %{
          name: atom(),
          base_url: String.t(),
          api_key: String.t() | nil,
          model: String.t(),
          max_retries: non_neg_integer(),
          receive_timeout: timeout(),
          usd_per_million_input: number(),
          req_options: keyword()
        }

  @doc """
  Evaluates `questions` against `state`.

  Returns `{:ok, reply}` with the map described in `Jev`, or `{:error, error}`
  where `error` is a `Jev.Error` for a non-2xx response, a `JSONCodec.Error`
  for a 200 whose body does not fit `Jev.Wire`, or the transport exception.
  Raises `ArgumentError` for malformed questions, an unknown endpoint, or a
  missing TypeSafe API key.
  """
  @spec post(Jev.entry(), keyword(Jev.shorthand()) | %{atom() => Jev.shorthand()}, [option()]) ::
          {:ok, Jev.reply()} | {:error, Jev.Error.t() | JSONCodec.Error.t() | Exception.t()}
  def post(state, questions, opts \\ []) do
    questions = Jev.questions(questions)
    endpoint = endpoint(opts)

    metadata = %{
      endpoint: endpoint.name,
      model: endpoint.model,
      questions: Map.new(questions, fn {name, %{type: type}} -> {name, type} end),
      state_hash: :erlang.phash2(state),
      tag: opts[:tag]
    }

    :telemetry.span([:jev, :request], metadata, fn ->
      case request(state, questions, endpoint) do
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

  @doc """
  Resolves the endpoint a call with `opts` would use.

  `opts[:endpoint]`, then `config :jev, endpoint:`, then `:typesafe` names the
  endpoint. `:typesafe` is built from the top-level configuration; any other
  name is looked up under `config :jev, endpoints:`. Per-call `base_url`,
  `api_key`, `model`, `max_retries`, and `receive_timeout` override the result.

      iex> Jev.HTTP.endpoint(endpoint: :local, model: "laya-421m").model
      "laya-421m"

  Raises `ArgumentError` for an unknown name or a named endpoint without a
  `base_url`.
  """
  @spec endpoint([option()]) :: endpoint()
  def endpoint(opts \\ []) do
    name = Keyword.get(opts, :endpoint) || config(:endpoint, :typesafe)
    base = if name == :typesafe, do: typesafe(), else: named(name)

    Enum.reduce(@overridable, base, fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp typesafe do
    Map.merge(transport(), %{
      name: :typesafe,
      base_url: config(:base_url, @default_base_url),
      api_key: config(:api_key) || System.get_env("TYPESAFE_API_KEY"),
      model: config(:model, @default_model),
      usd_per_million_input: config(:usd_per_million_input, @default_price)
    })
  end

  defp named(name) do
    settings =
      config(:endpoints, [])[name] ||
        raise ArgumentError,
              "unknown endpoint #{inspect(name)}; define it with " <>
                "config :jev, endpoints: [#{name}: [base_url: \"...\"]]"

    base_url =
      settings[:base_url] || raise ArgumentError, "endpoint #{inspect(name)} needs a :base_url"

    transport()
    |> Map.merge(Map.take(Map.new(settings), [:max_retries, :receive_timeout, :req_options]))
    |> Map.merge(%{
      name: name,
      base_url: base_url,
      api_key: settings[:api_key],
      model: settings[:model] || @default_model,
      usd_per_million_input: settings[:usd_per_million_input] || 0.0
    })
  end

  defp transport do
    %{
      max_retries: config(:max_retries, 3),
      receive_timeout: config(:receive_timeout, 30_000),
      req_options: config(:req_options, [])
    }
  end

  defp request(state, questions, endpoint) do
    body = JSON.encode!(%{model: endpoint.model, state: state, questions: questions})

    request =
      Req.new(
        [
          base_url: endpoint.base_url,
          headers: [accept: "application/json", content_type: "application/json"],
          decode_body: false,
          retry: &retry?/2,
          max_retries: endpoint.max_retries,
          receive_timeout: endpoint.receive_timeout
        ] ++ auth(endpoint) ++ endpoint.req_options
      )

    case Req.post(request, url: "/v1/systemone", body: body) do
      {:ok, %Req.Response{status: 200, body: body} = response} ->
        with {:ok, wire} <- Jev.Wire.Response.from_map(JSON.decode!(body)) do
          price = endpoint.usd_per_million_input
          {:ok, Jev.reply(wire, questions, usd_per_million_input: price), request_id(response)}
        end

      {:ok, %Req.Response{status: status, body: body} = response} ->
        error = %Jev.Error{
          status: status,
          body: decode(body),
          request_id: request_id(response),
          endpoint: endpoint.name
        }

        {:error, error}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp retry?(_request, %Req.Response{status: status}), do: status in [429, 529]
  defp retry?(_request, _exception), do: true

  defp auth(%{name: :typesafe, api_key: nil}) do
    raise ArgumentError, "pass :api_key, set config :jev, api_key: ..., or set TYPESAFE_API_KEY"
  end

  defp auth(%{api_key: nil}), do: []
  defp auth(%{api_key: key}), do: [auth: {:bearer, key}]

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
