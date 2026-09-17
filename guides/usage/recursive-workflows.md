# Recursive Workflows

Recursion with Jev is a `handle_answer/3` clause that replies again. Every
recursive workflow has the same three parts: context in the tag, a base case
as a clause, and a bound in a guard.

## Tree descent

A choice is limited to 255 options, and the
[hierarchical classification cookbook](https://docs.typesafe.ai/cookbooks/hierarchical_classification)
handles bigger spaces by descending one level per call. Over a DOM that is one
question per level among the children, stopping when confidence drops or depth
runs out:

```elixir
defmodule Locate do
  use Jev.Server

  @max_depth 8

  def init(_), do: {:ok, %{}}

  def handle_cast({:locate, page, reply_to}, s), do: descend(page, page.root, 0, reply_to, s)

  def handle_answer(%{which: pick, confidence: %{which: c}}, {page, node, depth, reply_to}, s)
      when c > 0.6 and depth < @max_depth do
    child = Enum.at(children(node), pick |> Atom.to_string() |> String.to_integer())
    descend(page, child, depth + 1, reply_to, s)
  end

  def handle_answer(_reply, {_page, node, _depth, reply_to}, s), do: found(node, reply_to, s)

  defp descend(page, node, depth, reply_to, s) do
    case children(node) do
      kids when length(kids) < 2 ->
        found(node, reply_to, s)

      kids ->
        options = kids |> Enum.with_index() |> Map.new(fn {kid, i} -> {:"#{i}", summary(kid)} end)
        state = %{title: page.title, parent: summary(node)}
        {:reply, {{page, node, depth, reply_to}, state, which: {"Which child holds the article body?", options}}, s}
    end
  end

  defp found(node, reply_to, s) do
    send(reply_to, {:located, node})
    {:noreply, s}
  end
end
```

Each level costs one request. Stopping when confidence drops is the natural
base case, and it is also where you learn whether confidence at deep levels is
trustworthy for your data.

## Bisection

"Where does this document talk about refunds?" costs log n calls instead of
scoring every paragraph. Ask about both halves at once; when both come back
likely, follow both, and the recursion becomes a tree search that returns
several spots:

```elixir
def handle_answer({{:bisect, chunk}, %{left: l, right: r}}, s) when l > 0.5 and r > 0.5,
  do: {:noreply, s |> bisect(left(chunk)) |> bisect(right(chunk))}

def handle_answer({{:bisect, chunk}, %{left: l}}, s) when l > 0.5, do: bisect(s, left(chunk))
def handle_answer({{:bisect, chunk}, %{right: r}}, s) when r > 0.5, do: bisect(s, right(chunk))
def handle_answer({{:bisect, _chunk}, _reply}, s), do: {:noreply, s}

defp bisect(s, chunk) when byte_size(chunk) < 800, do: hit(s, chunk)

defp bisect(s, chunk) do
  {:reply, {{:bisect, chunk}, chunk,
     left: "Does the first half mention refunds?",
     right: "Does the second half mention refunds?"}, s}
end
```

## Verify and repair

Extract each field as a choice over parsed candidates, verify every field with
a yes/no question framed so that true means "something is wrong", and re-ask
any flagged field with the rejected candidate removed. The candidate lists
shrink, so it terminates by construction. This is the
[extraction cascade](https://docs.typesafe.ai/cookbooks/sde_cascade) with the
expensive model replaced by another round of Jev:

```elixir
def handle_answer({{:verify, doc, picks, candidates}, reply}, s) do
  case for {field, p} <- reply, is_float(p) and p > 0.7, do: field do
    [] ->
      {:noreply, done(s, picks)}

    bad ->
      remaining = Map.new(candidates, fn {f, cs} -> {f, if(f in bad, do: cs -- [picks[f]], else: cs)} end)
      extract(s, doc, Map.drop(picks, bad), remaining)
  end
end
```

## Cascade

Ask a broad question; if unsure, ask a narrower one, possibly of a different
model. The tag records the stage:

```elixir
def handle_answer(%{kind: k, confidence: %{kind: c}}, {:broad, text}, s) when c < 0.5 do
  {:reply, {{:narrow, text}, text, [kind: {"Which fits better?", top_two(k)}], [model: "jev-preview"]}, s}
end

def handle_answer(%{kind: k}, {_stage, text}, s), do: classified(text, k, s)
```

## Crawling

The recursion can cross processes. A page server asks a score question per
outgoing link for crawl priority and, for each link above the bar, starts a
child page server under a `DynamicSupervisor`. A `Registry` keyed by URL
dedupes, the depth lives in the child's init argument, and the whole crawl is
a supervision tree you can watch in Observer.

## Clarifying conversation

Intent routing where a middling confidence asks the user a clarifying question
instead of acting. Their reply is appended to the thread list in the state and
the same intent question is asked again. Bound it by turn count in the tag.
