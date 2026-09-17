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

Then stub responses shaped like the API:

```elixir
Req.Test.stub(Jev.HTTP, fn conn ->
  conn
  |> Plug.Conn.put_resp_content_type("application/json")
  |> Plug.Conn.send_resp(200, JSON.encode!(%{
    "model" => "jev-1.13.0",
    "answers" => %{"kind" => %{"type" => "choice", "choice" => "bug", "confidence" => 0.9, "probabilities" => %{"bug" => 0.9, "other" => 0.1}}},
    "usage" => %{"input_tokens" => 100, "output_tokens" => 0}
  }))
end)

assert {:ok, %{kind: :bug}} = Jev.HTTP.post("state", kind: {"Kind?", %{bug: nil, other: nil}})
```

`Req.Test.transport_error/2` simulates a connection failure, and a stub that
returns 429 or 529 exercises the retry path.

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

A stub can read the request body to answer differently per call, which is how
to test a server with several requests in flight or a recursive workflow that
asks a second question based on the first answer.

## Live

The repository's `examples/triage.exs` is a live smoke test against the API:

```sh
TYPESAFE_API_KEY=... mix run examples/triage.exs
```
