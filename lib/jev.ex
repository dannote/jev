defmodule Jev do
  @moduledoc """
  TypeSafe Jev for OTP.

  Questions are data, the reply is a plain map, and `Jev.Server` lets a
  GenServer talk to Jev by replying:

      def handle_call({:labels, issue}, from, s) do
        {:reply, {from, issue,
           kind: {"What kind of issue?", %{bug: nil, feature: nil, other: nil}},
           security: "Is this a vulnerability?"}, s}
      end

      def handle_answer(%{security: p}, from, s) when p > 0.5, do: done(from, [:security], s)
      def handle_answer(%{kind: k, confidence: %{kind: c}}, from, s) when c > 0.85, do: done(from, [k], s)
      def handle_answer(%{kind: k}, from, s), do: done(from, [k, :"needs-triage"], s)

  This module holds the pure half: `questions/1` normalizes shorthands into
  `Jev.Noul`, `Jev.Choice`, and `Jev.Score` structs, and `reply/2` turns a
  decoded API response into the reply map. `Jev.HTTP.post/3` is the transport.

  ## The reply map

      %{
        kind: :bug,            # Choice → label atom
        severity: 2.4,         # Score  → expected level, float
        security: 0.03,        # Noul   → probability of yes
        confidence: %{kind: 0.91, severity: 0.62},
        probabilities: %{kind: %{bug: 0.93, feature: 0.04, other: 0.03},
                         severity: %{0 => 0.1, 1 => 0.1, 2 => 0.2, 3 => 0.6}},
        usage: %{input_tokens: 812, output_tokens: 0, cost: 3.4e-5},
        model: "jev-1.13.0"    # the concrete model that answered, even when you asked for jev-latest
      }

  `confidence`, `probabilities`, `usage`, and `model` are reserved question names.

  ## Other models

  The wire format is served by open decision models as well as by TypeSafe,
  and `reply/3` accepts what they send: `usage` may be missing, and when an
  answer carries probabilities but no `confidence`, confidence is computed the
  way TypeSafe defines it, as the top probability normalized over the number
  of options, `(top - 1/k) / (1 - 1/k)`. Servers are calibrated differently,
  so a threshold tuned on one model is a starting point on another, not a
  guarantee.
  """

  @typedoc "Text, a JSON-encodable map or list, or `nil`."
  @type entry :: String.t() | map() | list() | nil

  @type question :: Jev.Noul.t() | Jev.Choice.t() | Jev.Score.t()

  @typedoc """
  A question in one of the accepted shorthands:

    * a string or map: `Jev.Noul` instructions
    * `{instructions, %{label => description}}`: `Jev.Choice`
    * `{instructions, [level, ...]}`: `Jev.Score`
    * a question struct, passed through
  """
  @type shorthand ::
          entry() | {entry(), %{atom() => entry()}} | {entry(), [entry(), ...]} | question()

  @type questions :: %{atom() => question()}

  @type usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cost: float()
        }

  @type reply :: %{
          optional(atom()) => atom() | float(),
          confidence: %{atom() => float()},
          probabilities: %{atom() => %{(atom() | non_neg_integer()) => float()}},
          usage: usage(),
          model: String.t() | nil
        }

  @reserved [:confidence, :probabilities, :usage, :model]

  @doc """
  Normalizes a keyword list or map of questions into question structs.

      iex> Jev.questions(security: "Is this a vulnerability?")
      %{security: %Jev.Noul{instructions: "Is this a vulnerability?"}}

      iex> Jev.questions(kind: {"What kind?", %{bug: "Broken", other: nil}})
      %{kind: %Jev.Choice{instructions: "What kind?", criteria: %{bug: "Broken", other: nil}}}

      iex> Jev.questions(severity: {"How severe?", ["Cosmetic", "Blocks"]})
      %{severity: %Jev.Score{instructions: "How severe?", criteria: ["Cosmetic", "Blocks"]}}

  Raises `ArgumentError` for an empty list, a reserved name, a choice outside
  2..255 options, or a score outside 2..10 levels.
  """
  @spec questions(keyword(shorthand()) | %{atom() => shorthand()}) :: questions()
  def questions(questions) when is_list(questions) or is_map(questions) do
    if Enum.empty?(questions), do: raise(ArgumentError, "at least one question is required")

    Map.new(questions, fn
      {name, _} when name in @reserved ->
        raise ArgumentError, "#{inspect(name)} is a reserved question name"

      {name, shorthand} when is_atom(name) ->
        {name, question(name, shorthand)}
    end)
  end

  defp question(_name, %mod{} = q) when mod in [Jev.Noul, Jev.Choice, Jev.Score], do: q

  defp question(_name, instructions) when is_binary(instructions) or is_map(instructions),
    do: %Jev.Noul{instructions: instructions}

  defp question(name, {instructions, %{} = options}) do
    unless map_size(options) in 2..255 and Enum.all?(options, fn {k, _} -> is_atom(k) end) do
      raise ArgumentError, "choice #{inspect(name)} needs 2 to 255 atom-labelled options"
    end

    %Jev.Choice{instructions: instructions, criteria: options}
  end

  defp question(name, {instructions, levels}) when is_list(levels) do
    unless length(levels) in 2..10 do
      raise ArgumentError, "score #{inspect(name)} needs 2 to 10 levels"
    end

    %Jev.Score{instructions: instructions, criteria: levels}
  end

  defp question(name, other) do
    raise ArgumentError, "question #{inspect(name)} has an unrecognized shape: #{inspect(other)}"
  end

  @doc """
  Turns a decoded API response body into the reply map.

  The questions are needed to map labels back to atoms: the criteria keys are
  the only atoms this function can produce, so no atoms are created from input.

  `usd_per_million_input:` prices the usage; it defaults to the configured
  price, see `cost/2`.
  """
  @spec reply(map(), questions(), [{:usd_per_million_input, number()}]) :: reply()
  def reply(%{"answers" => answers} = body, questions, opts \\ []) do
    price = Keyword.get_lazy(opts, :usd_per_million_input, &configured_price/0)

    base = %{
      confidence: %{},
      probabilities: %{},
      usage: usage(body["usage"], price),
      model: body["model"]
    }

    Enum.reduce(answers, base, fn {name, answer}, acc ->
      name = String.to_existing_atom(name)
      put_answer(acc, name, Map.fetch!(questions, name), answer)
    end)
  end

  defp usage(usage, price) do
    input = (usage && usage["input_tokens"]) || 0
    output = (usage && usage["output_tokens"]) || 0
    %{input_tokens: input, output_tokens: output, cost: cost(input, price)}
  end

  @doc """
  The cost in USD of `input_tokens` at `usd_per_million_input`.

  Jev bills input tokens only. The price defaults to TypeSafe's, 0.042 USD per
  million, and can be set with `config :jev, usd_per_million_input: 0.042`.
  Named endpoints carry their own price, zero unless configured.

      iex> Jev.cost(500_000, 1.0)
      0.5
  """
  @spec cost(non_neg_integer(), number()) :: float()
  def cost(input_tokens, usd_per_million_input \\ configured_price()) do
    input_tokens * usd_per_million_input / 1_000_000
  end

  defp configured_price, do: Application.get_env(:jev, :usd_per_million_input, 0.042)

  defp put_answer(acc, name, %Jev.Noul{}, %{"noul" => probability}),
    do: Map.put(acc, name, probability)

  defp put_answer(acc, name, %Jev.Choice{criteria: criteria}, %{"choice" => label} = answer) do
    labels = Map.new(criteria, fn {atom, _} -> {Atom.to_string(atom), atom} end)
    probabilities = probabilities(answer, &Map.fetch!(labels, &1))

    acc
    |> Map.put(name, Map.fetch!(labels, label))
    |> put_in([:confidence, name], confidence(answer, probabilities, map_size(criteria)))
    |> put_in([:probabilities, name], probabilities)
  end

  defp put_answer(acc, name, %Jev.Score{criteria: levels}, %{"score" => score} = answer) do
    probabilities = probabilities(answer, &String.to_integer/1)

    acc
    |> Map.put(name, score)
    |> put_in([:confidence, name], confidence(answer, probabilities, length(levels)))
    |> put_in([:probabilities, name], probabilities)
  end

  defp probabilities(answer, key_fun) do
    Map.new(answer["probabilities"] || %{}, fn {key, p} -> {key_fun.(key), p} end)
  end

  # TypeSafe's definition: the top probability, rescaled so that a uniform
  # distribution over k options is 0 and certainty is 1.
  defp confidence(%{"confidence" => c}, _probabilities, _k) when is_number(c), do: c

  defp confidence(_answer, probabilities, k) when map_size(probabilities) > 0 do
    top = probabilities |> Map.values() |> Enum.max()
    max((top - 1 / k) / (1 - 1 / k), 0.0)
  end

  defp confidence(_answer, _probabilities, _k), do: nil
end
