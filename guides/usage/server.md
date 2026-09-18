# Server

`Jev.Server` is a GenServer that talks to Jev by replying. It owns the real
GenServer callbacks and delegates to your module, the way `GenStage` and
`Agent` are built, so every GenServer facility keeps working.

## Callbacks

Your module implements `init/1`, any of the usual `handle_call/3`,
`handle_cast/2`, `handle_info/2`, `handle_continue/2`, and one new callback:

```elixir
handle_answer(reply | {:error, reason}, tag, state)
```

Message, tag, state mirrors `handle_call`'s message, from, state.

## Sending to Jev

From any callback, return

```elixir
{:reply, {tag, state, questions}, your_state}
```

and the request is posted under `Jev.TaskSupervisor` without blocking the
server. `tag` is any term; it comes back with the answer. `state` is what the
questions are about. `questions` is a keyword list or map in any of the
[shorthands](questions.md).

Per-request options such as `model:` go in a fourth element. The questions
then need their own brackets:

```elixir
{:reply, {tag, state, [kind: {"Which?", %{a: nil, b: nil}}], [model: "jev-preview"]}, s}
```

The other return values are the GenServer ones: `{:noreply, s}`,
`{:noreply, s, timeout | :hibernate | {:continue, term}}`, and
`{:stop, reason, s}`.

## Answering callers

Because the answer is not known when `handle_call/3` returns, callers are
answered later with `GenServer.reply/2`. Passing `from` as the tag is the
common case:

```elixir
def handle_call({:labels, issue}, from, s), do: {:reply, {from, issue, @questions}, s}

def handle_answer(%{kind: k}, from, s) do
  GenServer.reply(from, [k])
  {:noreply, s}
end
```

Set the call timeout with the API latency in mind. A budget of 30 seconds
covers the default receive timeout plus retries.

## Requests in flight

A server can have any number of requests outstanding. Each reply carries its
tag, so a clause knows which caller, page, or step it belongs to. The
`pending` map in the wrapper state holds the outstanding task references, and
`:sys.get_status/1` shows your inner state rather than the wrapper.

## Errors

Every failure arrives at `handle_answer/3` as `{:error, reason}`:

- a non-2xx response after retries, as `{:error, %Jev.Error{status: status, body: body, request_id: id}}`
- a transport failure, as `{:error, %Req.TransportError{}}` or another exception
- a crashed request, for example state that cannot be encoded, as `{:error, {exception, stacktrace}}`

The request runs under `Task.Supervisor.async_nolink/4`, so the crash never
reaches the server. A retry is just a clause that replies again:

```elixir
def handle_answer({:error, %Jev.Error{status: 529}}, {attempt, issue} = tag, s) when attempt < 3 do
  {:reply, {{attempt + 1, issue}, issue, @questions}, s}
end
```

Note that `Jev.HTTP` already retries 429 and 529 with backoff before the error
reaches you, so this is for the rare case that outlives those retries.

## Routing on the reply

The reply is a plain map, so routing is pattern matching in clause order:

```elixir
# A security flag wins regardless of the rest.
def handle_answer(%{security: p}, from, s) when p > 0.5, do: done(from, [:security], s)

# Confident and serious.
def handle_answer(%{kind: :bug, severity: sev, confidence: %{kind: c}}, from, s)
    when c > 0.85 and sev >= 2,
    do: done(from, [:bug, :"priority:high"], s)

# Confident enough to act.
def handle_answer(%{kind: k, confidence: %{kind: c}}, from, s) when c > 0.6, do: done(from, [k], s)

# Too close to call: hand the top two to a human.
def handle_answer(%{probabilities: %{kind: ps}}, from, s) do
  [a, b | _] = ps |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.map(&elem(&1, 0))
  done(from, [:"needs-triage", {:one_of, a, b}], s)
end
```

The TypeSafe [confidence guide](https://docs.typesafe.ai/confidence) suggests
acting above 0.9, confirming between 0.5 and 0.9, and escalating below 0.5,
with stricter thresholds for actions that are harder to reverse. Those are
three guards.

## Lifecycle

`init/1` may return `{:ok, state, {:continue, term}}` or `{:ok, state, timeout}`
as with any GenServer, and `handle_continue/2` is delegated. `terminate/2` and
`code_change/3` are delegated when your module defines them. Two GenServer
rules carry over unchanged: `terminate/2` runs on a supervisor shutdown only
if the process traps exits, and a restart starts from `init/1` again.

That second rule matters for requests in flight. A restarted server has an
empty pending map, so answers to requests the old process sent are dropped.
Callers blocked in `GenServer.call/3` get the exit they would get from any
crashed GenServer. Cast-driven work, such as a multi-step descent, is lost
silently, so keep the position in durable state if a step must not be skipped.

## Starting a server

`use Jev.Server` defines a `child_spec/1`, so a server goes in a supervision
tree like any other child, and takes the same child spec options `use GenServer`
does:

```elixir
use Jev.Server, restart: :temporary   # one server per page under a DynamicSupervisor

children = [
  {Triage, []},
  {Jev.Server, [Locate, page]}   # or explicitly
]
```

The default `handle_call/3`, `handle_cast/2`, and `handle_info/2` behave like
GenServer's: an unexpected call or cast stops the server with a "no clause was
provided" error, and an unexpected message is logged and ignored.

`Jev.Server.start_link/3` takes the module, the init argument, and
`GenServer.start_link/3` options such as `name:`.

The `:jev` application starts `Jev.TaskSupervisor`, which the servers post
through. Nothing else needs to be started.
