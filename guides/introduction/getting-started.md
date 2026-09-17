# Getting Started

## Installation

Add Jev to your dependencies:

```elixir
def deps do
  [{:jev, "~> 0.1"}]
end
```

Jev requires Elixir 1.18 or later, for the built-in `JSON` module, and Erlang/OTP 27 or later.

## API key

Set `TYPESAFE_API_KEY` in the environment, or configure it:

```elixir
# config/runtime.exs
config :jev, api_key: System.fetch_env!("TYPESAFE_API_KEY")
```

Keys come from the [TypeSafe dashboard](https://docs.typesafe.ai/introduction/quickstart).

## First call

`Jev.HTTP.post/3` sends questions about a piece of state and returns a plain map:

```elixir
{:ok, reply} =
  Jev.HTTP.post("My flight was cancelled. Can I get a refund?",
    refund: "Does the customer want money returned?",
    request: {"What is the main request?", %{refund: nil, rebooking: nil, information: nil}},
    frustration: {"How frustrated is the customer?", ["Calm", "Concerned but civil", "Angry"]}
  )

reply.refund       #=> 0.97
reply.request      #=> :refund
reply.frustration  #=> 0.6
reply.confidence   #=> %{request: 0.95, frustration: 0.7}
```

A bare string is a yes/no question and comes back as a probability. A tuple with
a map of labels is a choice and comes back as the label. A tuple with a list of
levels is a score and comes back as the expected level. See [Questions](questions.md).

## First server

The point of the library is `Jev.Server`. Instead of calling Jev, a server
replies to it and gets the answer back as a callback:

```elixir
defmodule Refunds do
  use Jev.Server

  def init(_), do: {:ok, %{}}

  def handle_call({:route, message}, from, s) do
    {:reply, {from, message,
       request: {"What is the main request?", %{refund: nil, rebooking: nil, information: nil}}}, s}
  end

  def handle_answer(%{request: r, confidence: %{request: c}}, from, s) when c > 0.85 do
    GenServer.reply(from, {:route_to, r})
    {:noreply, s}
  end

  def handle_answer(%{request: r}, from, s) do
    GenServer.reply(from, {:confirm_with_user, r})
    {:noreply, s}
  end
end
```

```elixir
{:ok, pid} = Jev.Server.start_link(Refunds, [])
GenServer.call(pid, {:route, "My flight was cancelled. Can I get a refund?"})
#=> {:route_to, :refund}
```

The server does not block while Jev thinks. The caller's `from` rides along as
the tag, and the matching clause answers it when the reply lands. See
[Server](server.md) for the full callback contract.

## Running the example

The repository ships a triage example that sends four issues through one
server concurrently:

```sh
TYPESAFE_API_KEY=... mix run examples/triage.exs
```
