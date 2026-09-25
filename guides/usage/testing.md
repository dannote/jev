# Testing

Nothing below `handle_answer/3` touches the network, so most tests need no
transport at all. For the ones that do, `Req.Test` stands in for the API.

## Routing logic

`handle_answer/3` is a function. Call it with a literal reply:

```elixir
test "a security flag wins" do
  from = {self(), make_ref()}
  assert {:noreply, _} = Triage.handle_answer(%{security: 0.9, kind: :feature, confidence: %{kind: 0.99}}, from, %{})
  assert_receive {_, [:security]}
end
```

The reply map is documented in [Questions](questions.md). Only the keys a
clause matches on need to be present.

## The transport

Point the transport at a `Req.Test` plug in the test config. Disabling the
retry delay keeps retry tests fast:

```elixir
# config/config.exs
if config_env() == :test do
  config :jev,
    api_key: "test-key",
    req_options: [plug: {Req.Test, Jev.HTTP}, retry_delay: 0, retry_log_level: false]
end
```

Then answer with `Jev.Test.respond/2`, which reads the questions from the
request and writes the response the way you read a reply:

```elixir
Req.Test.stub(Jev.HTTP, &Jev.Test.respond(&1, kind: :bug, confidence: %{kind: 0.9}))

assert {:ok, %{kind: :bug, confidence: %{kind: 0.9}}} =
         Jev.HTTP.post("state", kind: {"Kind?", %{bug: nil, other: nil}})
```

A choice is its label, a score its value, a yes/no its probability. Give
`probabilities` when a clause depends on the whole distribution; otherwise
the body carries the distribution implied by the confidence, so
`Jev.confidence/2` of what comes back equals what you said. `model` and
`usage` are reserved keys too, and answers may be partial.

Failures are `Jev.Test.error/3`, which sends a body the client turns into a
`Jev.Error`, and `Req.Test.transport_error/2` for a connection failure. A stub
that returns 429, 529, or a gateway error such as 503 exercises the retry path:

```elixir
Req.Test.stub(Jev.HTTP, &Jev.Test.error(&1, 529, "overloaded"))
```

`Jev.Test.body/2` is the pure half, a wire body from a reply and the
questions, for tests that do not go through `Req.Test`. `Jev.Test.request/1`
reads the request out of a `conn`, so a stub can answer differently per state:

```elixir
Req.Test.stub(Jev.HTTP, fn conn ->
  {request, conn} = Jev.Test.request(conn)

  case request["state"]["title"] do
    "leak" -> Jev.Test.respond(conn, security: 0.9)
    _ -> Jev.Test.respond(conn, kind: :bug, security: 0.01)
  end
end)
```

## Servers

A `Jev.Server` posts from a task process, so the stub must be visible outside
the test process. Use shared mode and `async: false`:

```elixir
defmodule TriageTest do
  use ExUnit.Case, async: false

  setup {Req.Test, :set_req_test_to_shared}

  test "routes a crash report" do
    Req.Test.stub(Jev.HTTP, &crash_report/1)
    pid = start_supervised!({Triage, []})
    assert GenServer.call(pid, {:labels, %{title: "crash"}}) == [:bug, :"priority:high"]
  end
end
```

Answering differently per request, as above, is how to test a server with
several requests in flight or a recursive workflow that asks a second question
based on the first answer.

## Live

Two scripts talk to a real server. `examples/triage.exs` asks Jev:

```sh
TYPESAFE_API_KEY=... mix run examples/triage.exs
```

`examples/local.exs` asks anything that speaks the wire format, and checks
what a stub cannot: that a server we did not write is understood, that a
named endpoint sends its key and bills nothing, and that a rejected key
becomes a `Jev.Error`.

```sh
JEV_LOCAL_URL=http://localhost:8000 JEV_LOCAL_KEY=devkey mix run examples/local.exs
```

The bodies those servers return are worth keeping. `test/fixtures/conformance`
holds one per implementation, and `Jev.ConformanceTest` decodes each one, which
is how a server drifting away from the client gets noticed.
