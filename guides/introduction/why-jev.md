# Why Jev

[TypeSafe Jev](https://docs.typesafe.ai) is not a chat model. It takes a piece
of state and a set of typed questions, and returns typed answers with
probabilities: a label from a list, a level on a scale, or the probability that
a statement is true. It never generates text. That makes it a decision
primitive, and decision primitives belong in code that already knows how to
route on data.

## The reply is a message

The official SDKs are promise-shaped: call, await, read fields off a response
object. On the BEAM the natural shape is different. A process sends a message
and, some time later, receives one. `Jev.Server` takes that literally. You
reply to Jev from a callback, and its answer arrives at `handle_answer/3`,
where the reply is a plain map:

```elixir
def handle_answer(%{security: p}, from, s) when p > 0.5, do: done(from, [:security], s)
def handle_answer(%{kind: k, confidence: %{kind: c}}, from, s) when c > 0.85, do: done(from, [k], s)
def handle_answer(%{kind: k}, from, s), do: done(from, [k, :"needs-triage"], s)
```

Clause order is the routing. Confidence thresholds are guards. Nothing in that
module touches the network, so tests construct maps and call the function.

## Why not structs for answers

Every version of this library that wrapped answers in structs made the
callbacks worse. `%{kind: :bug}` matches; `%{kind: %Answer{value: :bug}}` is
noise in every clause. So the reply is a map with your question names as keys,
and the distribution lives beside them under `confidence` and `probabilities`
for the clauses that want it.

## Why not helpers

The [TypeSafe patterns](https://docs.typesafe.ai/patterns) are confidence
gating, fan-out, composite scoring, and intent routing. In Python they are
chains of `if`. In Elixir they are function heads, `with` clauses that accept
guards, and `Enum` over the probabilities map. There is nothing for a helper
module to add, and the library has none.

## Why not a chat client

Jev fits an LLM client library as plumbing: keys, retries, telemetry, cost. It
does not fit as a paradigm. Questions as data, fan-out over one state, and
confidence as a routing axis are not things a chat abstraction expresses, and
forcing them into a chat response struct hides what makes Jev useful. Jev is
therefore standalone. Its transport, `Jev.HTTP`, is a single function that you
can swap for another client if you already run one.

## What OTP adds

- A server holds any number of requests in flight; tags tell the answers apart.
- Requests run under a task supervisor, so a crashed request becomes an error
  answer instead of taking the server down.
- Recursion is a clause that replies again. Tree descent, bisection, and
  verify-and-repair loops are a few lines each. See [Recursive Workflows](recursive-workflows.md).
- Telemetry carries tokens, cost, and every confidence value, so calibration
  monitoring and evaluation harnesses attach without changing call sites.
