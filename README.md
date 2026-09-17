# Jev

[![Hex.pm](https://img.shields.io/hexpm/v/jev.svg)](https://hex.pm/packages/jev) [![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/jev) [![CI](https://github.com/dannote/jev/actions/workflows/ci.yml/badge.svg)](https://github.com/dannote/jev/actions/workflows/ci.yml)

[TypeSafe Jev](https://docs.typesafe.ai) for OTP.

Jev is a peer process. You reply to it from a GenServer, and its answer is a
message you pattern match on.

```elixir
defmodule Triage do
  use Jev.Server

  def init(_), do: {:ok, %{}}

  def handle_call({:labels, issue}, from, s) do
    {:reply, {from, issue,
       kind: {"What kind of issue is this?", %{bug: "Broken", feature: "New behavior", other: nil}},
       severity: {"How severe for users?", ["Cosmetic", "Workaround", "Blocks", "Data loss"]},
       security: "Does this describe a vulnerability?"}, s}
  end

  # Clause order is the routing. Thresholds are guards.
  def handle_answer(%{security: p}, from, s) when p > 0.5, do: done(from, [:security], s)

  def handle_answer(%{kind: :bug, severity: sev, confidence: %{kind: c}}, from, s)
      when c > 0.85 and sev >= 2,
      do: done(from, [:bug, :"priority:high"], s)

  def handle_answer(%{kind: k, confidence: %{kind: c}}, from, s) when c > 0.6, do: done(from, [k], s)
  def handle_answer(%{kind: k}, from, s), do: done(from, [k, :"needs-triage"], s)
  def handle_answer({:error, reason}, from, s), do: done(from, {:error, reason}, s)

  defp done(from, result, s) do
    GenServer.reply(from, result)
    {:noreply, s}
  end
end
```

Nothing below `handle_answer/3` touches the network, so tests call it with a
literal map. The server never blocks on Jev: a hundred calls can be in flight,
and each answer finds its clause when it lands.

## Installation

```elixir
def deps do
  [{:jev, "~> 0.1"}]
end
```

```elixir
config :jev, api_key: System.get_env("TYPESAFE_API_KEY")   # or just set TYPESAFE_API_KEY
```

Requires Elixir 1.18 or later, for the built-in `JSON` module, and Erlang/OTP 27 or later.

## Documentation

- [Getting Started](guides/introduction/getting-started.md) and [Why Jev](guides/introduction/why-jev.md)
- [Questions](guides/usage/questions.md), [Server](guides/usage/server.md), [Recursive Workflows](guides/usage/recursive-workflows.md)
- [Telemetry](guides/usage/telemetry.md) and [Testing](guides/usage/testing.md)
- [API cheatsheet](guides/cheatsheets/api.cheatmd)

## Questions

Three structs, one per TypeSafe primitive, and a shorthand for each, told apart
by the shape of the criteria:

```elixir
security: "Is this a vulnerability?"                                          # string   → Jev.Noul
kind:     {"What kind of issue?", %{bug: "Broken", feature: nil, other: nil}}  # {q, map}  → Jev.Choice
severity: {"How severe?", ["Cosmetic", "Workaround", "Blocks", "Data loss"]}   # {q, list} → Jev.Score
urgent:   %Jev.Noul{instructions: "Needs attention now?",
                    criteria: %{true: "Users blocked", false: "Workaround exists"}}
```

Every field the API accepts as JSON is a map or list in the struct. Structured
instructions and rubrics need nothing special:

```elixir
wrong: %Jev.Noul{instructions: %{field: spec, extracted_value: value,
                                 question: "Is `extracted_value` unsupported by the text given `field`?"}}

kind: {"What is the request?", %{
  billing:  %{what: "Charges, refunds", not_for: "Order tracking", examples: ["Charged twice"]},
  shipping: %{what: "Delivery status", examples: ["Where is my order"]}}}
```

State is any JSON-encodable term. For your own structs, derive with a field
list so trimming irrelevant state, which Jev is sensitive to, is declarative:

```elixir
@derive {JSON.Encoder, only: [:url, :title, :text]}
defstruct [:url, :title, :text, :dom, :headers]
```

## The reply

A plain map, so callbacks match on question names directly:

```elixir
%{
  kind: :bug,            # Choice → label atom
  severity: 2.4,         # Score  → expected level, float
  security: 0.03,        # Noul   → probability of yes
  confidence:    %{kind: 0.91, severity: 0.62},
  probabilities: %{kind: %{bug: 0.93, feature: 0.04, other: 0.03},
                   severity: %{0 => 0.1, 1 => 0.1, 2 => 0.2, 3 => 0.6}},
  usage: %{input_tokens: 812, output_tokens: 0, cost: 3.4e-5},
  model: "jev-1.13.0"    # the concrete model that answered
}
```

`confidence`, `probabilities`, `usage`, and `model` are reserved question names. Labels
come back as atoms safely: the criteria keys are the only atoms the parser can
produce.

Everything you might want on top is the standard library:

```elixir
with %{kind: k, confidence: %{kind: c}} when c > 0.85 <- reply, do: act(k)

[first, second | _] = reply.probabilities.kind |> Enum.sort_by(&elem(&1, 1), :desc)
level = round(reply.severity)
```

## `Jev.Server`

A GenServer that owns the real callbacks and delegates to yours, the way
`GenStage` and `Agent` are built. One new callback:

```elixir
handle_answer(reply | {:error, reason}, tag, state)
```

Message, tag, state mirrors `handle_call`'s message, from, state. From any
callback, `{:reply, {tag, state, questions}, s}` sends to Jev. The request runs
under a `Task.Supervisor`, so a crashed request becomes `{:error, reason}` in
`handle_answer/3` instead of taking the server down. Per-request options such
as `model:` go in a fourth element, with the questions in their own brackets.

Recursion is a `handle_answer` clause that replies again. Context rides in the
tag, the base case is a clause, the bound is a guard:

```elixir
def handle_answer(%{which: pick, confidence: %{which: c}}, {node, depth}, s)
    when c > 0.6 and depth < 8 do
  child = Enum.at(children(node), pick |> Atom.to_string() |> String.to_integer())
  {:reply, {{child, depth + 1}, summary(child), which: options(child)}, s}
end

def handle_answer(_reply, {node, _depth}, s), do: found(node, s)
```

## Without a server

`Jev.HTTP.post/3` is the transport and works on its own for scripts and
evaluation harnesses:

```elixir
{:ok, reply} = Jev.HTTP.post(issue, kind: {"Kind?", %{bug: nil, other: nil}}, security: "Vuln?")
```

It retries 429 and 529 with backoff, honouring `Retry-After`. Non-2xx responses
come back as `{:error, %Jev.Error{status: status, body: body, request_id: id}}`.

## Telemetry

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:jev, :request, :start]` | `system_time` | `model`, `questions`, `state_hash`, `tag` |
| `[:jev, :request, :stop]` | `duration`, `input_tokens`, `output_tokens`, `cost` | plus `status`, `request_id`, `confidence` |
| `[:jev, :request, :exception]` | `duration` | plus `kind`, `reason`, `stacktrace` |
| `[:jev, :answer]` | `confidence`, `probability` | `name`, `type`, `answer`, `state_hash`, `tag` |

The state is never in metadata, only its hash. A distribution on
`jev.answer.confidence` tagged by `name` is a calibration monitor:

```elixir
distribution("jev.answer.confidence", tags: [:name], reporter_options: [buckets: [0.5, 0.7, 0.85, 0.95]]),
sum("jev.request.stop.cost"),
summary("jev.request.stop.duration", unit: {:native, :millisecond})
```

Cost is input tokens at `config :jev, usd_per_million_input: 0.042`, Jev's
published price. It bills no output tokens.

## Configuration

```elixir
config :jev,
  api_key: "...",                      # default: TYPESAFE_API_KEY
  base_url: "https://api.typesafe.ai",
  model: "jev-latest",
  max_retries: 3,
  receive_timeout: 30_000,
  usd_per_million_input: 0.042,
  req_options: []                      # merged into Req.new/1
```

In tests, point the transport at a `Req.Test` plug:

```elixir
config :jev, api_key: "test", req_options: [plug: {Req.Test, Jev.HTTP}, retry_delay: 0]
```

## Development

```sh
mix deps.get
mix ci
TYPESAFE_API_KEY=... mix run examples/triage.exs   # live smoke test
```
