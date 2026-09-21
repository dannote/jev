defmodule Jev.Test do
  @moduledoc """
  Test helpers: wire bodies from reply-shaped maps.

  Most tests of a `Jev.Server` call `handle_answer/3` with a literal reply map
  and never touch the transport. The ones that do stub `Jev.HTTP` with
  `Req.Test`, and this module writes the stub's response the same way you
  read a reply: question names to answers, `confidence` and `probabilities`
  beside them.

      Req.Test.stub(Jev.HTTP, &Jev.Test.respond(&1, kind: :bug, security: 0.03))

  `respond/2` reads the questions from the request, so the stub only says what
  the answer is. `body/2` is the pure half for other transports:

      Jev.Test.body([kind: :bug, confidence: %{kind: 0.9}], kind: {"Kind?", %{bug: nil, other: nil}})
      #=> %{"model" => "jev-test", "answers" => %{"kind" => %{"type" => "choice", ...}}, ...}

  A choice is its label, a score its value, a yes/no its probability. Answers
  may be partial; a question with no answer is left out of the body, as the
  reply map tolerates. Reserved keys are the reply's own: `confidence`,
  `probabilities`, `model` (default `"jev-test"`), and `usage` (default zero).

  Probabilities you do not give are the distribution implied by the
  confidence you do, the inverse of how the client computes confidence from
  probabilities: the answer gets `c * (1 - 1/k) + 1/k` and the rest share the
  remainder. With neither, the answer has probability one. A score's
  distribution centres on its nearest level, and its `legend` is the levels.

  `respond/2` and `error/3` need `:plug`, which `Req.Test` needs as well.
  """

  alias Jev.Wire

  @reserved [:confidence, :probabilities, :model, :usage]

  @typedoc "Answers by question name, plus any of the reserved reply keys."
  @type reply :: keyword() | map()

  @doc """
  The wire body a server would send for `reply` to `questions`.

  `questions` are in any shorthand `Jev.questions/1` accepts, or the wire
  `"questions"` map of a request. Raises `ArgumentError` for an answer to an
  unknown question or a choice label outside the criteria.
  """
  @spec body(reply(), keyword() | map()) :: map()
  def body(reply, questions) do
    reply = Map.new(reply)
    kinds = kinds(questions)

    answers =
      reply
      |> Map.drop(@reserved)
      |> Map.new(fn {name, value} ->
        kind = Map.get(kinds, name) || raise ArgumentError, "no question named #{inspect(name)}"

        {Atom.to_string(name),
         answer(kind, value, reply[:confidence][name], reply[:probabilities][name])}
      end)

    usage = Map.merge(%{input_tokens: 0, output_tokens: 0}, Map.new(reply[:usage] || %{}))

    %Wire.Response{
      model: Map.get(reply, :model, "jev-test"),
      answers: answers,
      usage: struct!(Wire.Usage, usage)
    }
    |> JSONCodec.dump()
    |> prune()
    |> update_in(["answers"], &Map.new(&1, fn {name, answer} -> {name, trim(answer)} end))
  end

  # A yes/no answer has no distribution on the wire.
  defp trim(%{"type" => "noul"} = answer), do: Map.delete(answer, "probabilities")
  defp trim(answer), do: answer

  # Question kinds by name: :noul, {:choice, labels}, or {:score, levels}.
  defp kinds(%{} = questions) when is_map_key(questions, "questions"),
    do: kinds(questions["questions"])

  defp kinds(questions) do
    Map.new(questions, fn
      {name, %{"type" => type} = q} when is_binary(name) ->
        {String.to_existing_atom(name), wire_kind(type, q["criteria"])}

      {name, question} when is_atom(name) ->
        {name, kind(Jev.questions([{name, question}])[name])}
    end)
  end

  defp kind(%Jev.Noul{}), do: :noul
  defp kind(%Jev.Choice{criteria: c}), do: {:choice, Enum.map(Map.keys(c), &Atom.to_string/1)}
  defp kind(%Jev.Score{criteria: levels}), do: {:score, levels}

  defp wire_kind("noul", _criteria), do: :noul
  defp wire_kind("choice", criteria), do: {:choice, Map.keys(criteria)}
  defp wire_kind("score", levels), do: {:score, levels}

  defp answer(:noul, p, _confidence, _probabilities) when is_number(p),
    do: %Wire.Answer{type: :noul, noul: p}

  defp answer({:choice, labels}, label, confidence, probabilities) when is_atom(label) do
    label = Atom.to_string(label)

    label in labels ||
      raise ArgumentError, "#{inspect(label)} is not one of #{inspect(labels)}"

    probabilities = probabilities || distribution(labels, label, confidence)

    %Wire.Answer{
      type: :choice,
      choice: label,
      confidence: confidence || Jev.confidence(probabilities),
      probabilities: Map.new(probabilities, fn {k, p} -> {to_string(k), p} end)
    }
  end

  defp answer({:score, levels}, score, confidence, probabilities) when is_number(score) do
    indices = Enum.map(0..(length(levels) - 1), &Integer.to_string/1)
    nearest = score |> round() |> min(length(levels) - 1) |> max(0) |> Integer.to_string()
    probabilities = probabilities || distribution(indices, nearest, confidence)

    %Wire.Answer{
      type: :score,
      score: score,
      confidence: confidence || Jev.confidence(probabilities),
      legend: indices |> Enum.zip(levels) |> Map.new(),
      probabilities: Map.new(probabilities, fn {k, p} -> {to_string(k), p} end)
    }
  end

  defp answer(kind, value, _confidence, _probabilities) do
    raise ArgumentError, "#{inspect(value)} is not an answer to a #{inspect(kind)} question"
  end

  # The distribution with confidence `c` over `keys`, peaked at `top`.
  defp distribution(keys, top, c) do
    k = length(keys)
    c = c || 1.0
    p = c * (1 - 1 / k) + 1 / k
    rest = if k > 1, do: (1 - p) / (k - 1), else: 0.0
    Map.new(keys, fn key -> {key, if(key == top, do: p, else: rest)} end)
  end

  # The API omits absent fields; JSONCodec.dump/1 writes them as nil.
  defp prune(%{} = map) do
    map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new(fn {k, v} -> {k, prune(v)} end)
  end

  defp prune(other), do: other

  if Code.ensure_loaded?(Plug.Conn) do
    @doc """
    Answers a `Req.Test` stub with `reply`, reading the questions from the request.

        Req.Test.stub(Jev.HTTP, &Jev.Test.respond(&1, kind: :bug, confidence: %{kind: 0.95}))

    The request body is left decoded in `conn.assigns.jev_request` for
    assertions on the state or model.
    """
    @spec respond(Plug.Conn.t(), reply()) :: Plug.Conn.t()
    def respond(conn, reply) do
      {request, conn} = request(conn)
      Req.Test.json(conn, body(reply, request))
    end

    @doc """
    Answers a `Req.Test` stub with a `Jev.Error`-shaped failure.

        Req.Test.stub(Jev.HTTP, &Jev.Test.error(&1, 429, "rate limited"))
    """
    @spec error(Plug.Conn.t(), pos_integer(), String.t()) :: Plug.Conn.t()
    def error(conn, status, message) do
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{"error" => message})
    end

    @doc "Reads and decodes the request body, assigning it to `conn.assigns.jev_request`."
    @spec request(Plug.Conn.t()) :: {map(), Plug.Conn.t()}
    def request(%Plug.Conn{assigns: %{jev_request: request}} = conn), do: {request, conn}

    def request(conn) do
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      request = JSON.decode!(raw)
      {request, Plug.Conn.assign(conn, :jev_request, request)}
    end
  end
end
