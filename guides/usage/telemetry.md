# Telemetry

`Jev.Telemetry.span/4` emits four events around every request. `Jev.HTTP`
runs under it, and so should any `Jev.Backend` of your own. `Jev.Server` adds
nothing; it passes the tag through so a handler can attribute a call to the
request that caused it.

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:jev, :request, :start]` | `system_time` | `backend`, `endpoint`, `model`, `questions`, `state_hash`, `tag` |
| `[:jev, :request, :stop]` | `duration`, `input_tokens`, `output_tokens`, `cost` | plus `status`, `request_id`, `confidence` |
| `[:jev, :request, :exception]` | `duration` | plus `kind`, `reason`, `stacktrace` |
| `[:jev, :answer]` | `confidence`, `probability` | `name`, `type`, `answer`, plus the start metadata |

`questions` is a map of question name to type. `endpoint`, `model`, `status`,
and `request_id` come from `Jev.HTTP`; another backend puts what it knows in
their place. `confidence` on the stop event is the reply's confidence map. `[:jev, :answer]` fires once per question after
a successful call; for a yes/no question `probability` is the answer itself,
for a choice or score it is the probability of the winning option and
`confidence` is Jev's confidence value.

Two rules keep the events useful. The state is never in metadata, only its
`:erlang.phash2/1` hash, so handlers that log metadata cannot leak content.
And the tag is always there, even though it is opaque, because it is the only
way to attribute a slow or expensive call when a server has many in flight.

## Cost

`cost` is input tokens at the endpoint's price. Jev bills input only, at 0.042
USD per million tokens at the time of writing:

```elixir
config :jev, usd_per_million_input: 0.042
```

A named endpoint has its own `usd_per_million_input`, zero by default, so a
`sum` of `cost` tagged by `endpoint` is the bill per model.

## Metrics

With `Telemetry.Metrics`:

```elixir
summary("jev.request.stop.duration", unit: {:native, :millisecond}),
sum("jev.request.stop.cost"),
sum("jev.request.stop.input_tokens"),
counter("jev.request.exception.duration", tags: [:kind]),
distribution("jev.answer.confidence",
  tags: [:name, :endpoint],
  reporter_options: [buckets: [0.5, 0.7, 0.85, 0.95]]
)
```

The last one is a calibration monitor. If a question's confidence
distribution shifts, the question or the state serialization changed, or the
model did. The `model` metadata tells you which. Tagged by `endpoint`, it
also shows how differently two models are calibrated on the same question,
which is what decides where a cascade's escalation threshold goes.

## Evaluation harness

One handler on `[:jev, :answer]` that records the state hash, question name,
answer, and confidence is enough to join against ground truth by hash:

```elixir
:telemetry.attach("eval", [:jev, :answer], &Eval.record/4, table)

def record(_event, %{confidence: c}, %{state_hash: h, name: n, answer: a}, table) do
  :ets.insert(table, {{h, n}, a, c})
end
```

Production code and the harness then call the client the same way, and
calibration and coverage-versus-accuracy curves come from the table.
