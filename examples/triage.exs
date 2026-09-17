# Triage GitHub-style issues with a Jev.Server, live against the TypeSafe API.
#
#     TYPESAFE_API_KEY=... mix run examples/triage.exs
#
# Four issues go through one server concurrently. Each answer picks its
# handle_answer clause: a confident bug, a security leak, a feature, and a
# vague report that lands in needs-triage.

defmodule Triage do
  use Jev.Server

  @questions [
    kind:
      {"What kind of issue is this?",
       %{
         bug: "Something is broken or behaves unexpectedly",
         feature: "Request for new behavior or an enhancement",
         question: "Asks how to do something or for help",
         other: nil
       }},
    severity:
      {"How severe is this issue for users?",
       ["Cosmetic", "Workaround exists", "Blocks a common use case", "Data loss or crash"]},
    security: "Does this issue describe a security vulnerability?"
  ]

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:labels, issue}, from, s), do: {:reply, {from, issue, @questions}, s}

  # Clause order is the routing. Thresholds are guards.
  @impl true
  def handle_answer(%{security: p}, from, s) when p > 0.5, do: done(from, [:security], s)

  def handle_answer(%{kind: :bug, severity: sev, confidence: %{kind: c}}, from, s)
      when c > 0.85 and sev >= 2,
      do: done(from, [:bug, :"priority:high"], s)

  def handle_answer(%{kind: k, confidence: %{kind: c}}, from, s) when c > 0.6,
    do: done(from, [k], s)

  def handle_answer(%{kind: k}, from, s), do: done(from, [k, :"needs-triage"], s)
  def handle_answer({:error, reason}, from, s), do: done(from, {:error, reason}, s)

  defp done(from, result, s) do
    GenServer.reply(from, result)
    {:noreply, s}
  end
end

{:ok, pid} = Jev.Server.start_link(Triage, [])

issues = [
  %{title: "App crashes on launch", body: "Since 2.3.1 the app closes immediately on iOS 17."},
  %{title: "Passwords visible in debug log", body: "The auth module logs the raw password."},
  %{title: "Dark mode?", body: "Would be nice to have a dark theme."},
  %{title: "hmm", body: "it does not work"}
]

issues
|> Task.async_stream(fn issue -> {issue.title, GenServer.call(pid, {:labels, issue}, 30_000)} end)
|> Enum.each(fn {:ok, {title, labels}} ->
  IO.puts("#{String.pad_trailing(title, 34)} #{inspect(labels)}")
end)
