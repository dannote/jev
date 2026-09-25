defmodule Jev.HTTP do
  @moduledoc """
  The transport: one POST to `/v1/systemone` per call.

  This is the `Jev.Backend` for TypeSafe and every server that speaks its wire
  format, and the default. `Jev.Server` calls it from a task; scripts and
  evaluation harnesses call it directly.

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
  passed per call. Requests that fail with 429 or 529, or with a gateway error
  (502, 503, 504), are retried with backoff, honouring `Retry-After`.

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

  Every call runs under `Jev.Telemetry.span/4`, with `backend: Jev.HTTP`,
  the `endpoint` name, and the `model` in the metadata; the stop event adds
  `status` and `request_id`. The state itself is never put in metadata, only
  its hash.
  """

  @behaviour Jev.Backend

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
  @impl Jev.Backend
  def post(state, questions, opts \\ []) do
    questions = Jev.questions(questions)
    endpoint = endpoint(opts)

    metadata = %{
      backend: __MODULE__,
      endpoint: endpoint.name,
      model: endpoint.model,
      tag: opts[:tag]
    }

    Jev.Telemetry.span(state, questions, metadata, fn ->
      case request(state, questions, endpoint) do
        {:ok, reply, request_id} -> {:ok, reply, %{status: 200, request_id: request_id}}
        {:error, _} = error -> error
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

  # Rate limits, overload, and the gateway failures in front of any API: all transient.
  defp retry?(_request, %Req.Response{status: status}), do: status in [429, 502, 503, 504, 529]
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

  # One event per answered question; a server may leave a question out.
end
