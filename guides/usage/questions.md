# Questions

Jev answers three kinds of question. Each has a struct and a shorthand, and
`Jev.questions/1` turns a keyword list of either into a map of structs. The
shorthands are told apart by the shape of the criteria.

| Primitive | Struct | Shorthand | Answer |
| --- | --- | --- | --- |
| Noul (yes/no) | `Jev.Noul` | `"Is this a vulnerability?"` | probability of yes, 0..1 |
| Choice | `Jev.Choice` | `{"What kind?", %{bug: "Broken", other: nil}}` | the label, as an atom |
| Score | `Jev.Score` | `{"How severe?", ["Cosmetic", "Blocks", "Data loss"]}` | expected level, a float |

## Noul

A statement or question judged as true. A string or a map is instructions;
use the struct when you want to describe what counts as true and false:

```elixir
urgent: %Jev.Noul{
  instructions: "Does this need immediate attention?",
  criteria: %{true: "Users cannot use the service.", false: "A workaround exists."}
}
```

The answer is the probability itself. Put the threshold in a guard:

```elixir
def handle_answer(%{urgent: p}, tag, s) when p > 0.7, do: ...
```

## Choice

Two to 255 options with no order between them. Labels are atoms and come back
as atoms; descriptions are text, a map, or `nil`:

```elixir
kind: {"What kind of issue is this?", %{
  bug: "Something is broken or behaves unexpectedly",
  feature: "Request for new behavior",
  question: "Asks how to do something",
  other: nil
}}
```

The reply carries the winning label under the question name, a `confidence`
between 0 and 1, and the probability of every option:

```elixir
%{kind: :bug, confidence: %{kind: 0.91}, probabilities: %{kind: %{bug: 0.93, feature: 0.04, ...}}}
```

Labels are safe: `Jev.reply/2` only ever produces atoms that already exist as
criteria keys, so nothing in the response can create atoms.

## Score

Two to ten ordered levels, numbered from zero. The answer is the expected
level, which may fall between levels:

```elixir
severity: {"How severe is this issue for users?", [
  "Cosmetic or minor annoyance",
  "Noticeable, but a workaround exists",
  "Blocks a common use case",
  "Data loss, crash, or blocks production"
]}
```

```elixir
%{severity: 2.4, confidence: %{severity: 0.62}, probabilities: %{severity: %{0 => 0.1, 1 => 0.1, 2 => 0.2, 3 => 0.6}}}
```

`round/1` gives the nearest level and division by the number of levels minus
one gives a 0..1 ratio, when you want either.

## Structured instructions and criteria

Every field the API accepts as JSON is a map or list in the struct, and the
encoder recurses. The model reads backtick-quoted keys in instructions as
references into that structure, which is how the
[verification cookbook](https://docs.typesafe.ai/cookbooks/sde_cascade) works:

```elixir
wrong: %Jev.Noul{
  instructions: %{
    field: %{name: "invoice_number", type: "string", description: "The identifier printed on the invoice."},
    extracted_value: "4471",
    question: "Is `extracted_value` unsupported by, or absent from, the source text given `field`?"
  }
}
```

Rubrics are just values, so they can be module attributes shared across
servers that must agree on what a label means:

```elixir
@billing %{what: "Charges, invoices, refunds", not_for: "Order tracking", examples: ["I was charged twice"]}
@shipping %{what: "Delivery status", examples: ["Where is my order"]}

request: {"What is the main request?", %{billing: @billing, shipping: @shipping, other: nil}}
```

## State

State is the text or JSON the questions are about, and it is any
JSON-encodable term: a string, a map, a list. The
[state guide](https://docs.typesafe.ai/concepts/state) recommends a map with
descriptive keys so instructions can reference them.

Jev is text only and is sensitive to large irrelevant state, so trim before
you send. For your own structs, derive the encoder with a field list:

```elixir
@derive {JSON.Encoder, only: [:url, :title, :text]}
defstruct [:url, :title, :text, :dom, :headers]
```

`Map.take/2` at the call site covers the case where different questions want
different views of the same struct.

## Candidates

Jev never generates text. Extraction is therefore a choice over candidates
your code proposes, with index labels going out and `Enum.at/2` coming back:

```elixir
options = candidates |> Enum.with_index() |> Map.new(fn {c, i} -> {:"#{i}", summary(c)} end)
{:reply, {tag, page, author: {"Which of these is the article's author?", options}}, s}
```

```elixir
def handle_answer(%{author: pick}, tag, s) do
  author = Enum.at(candidates, pick |> Atom.to_string() |> String.to_integer())
  ...
end
```

Numbers, dates, and hex values are documented weak spots. Parse them in code
and give the model parsed candidates rather than asking it to compare them.

## The reply map

```elixir
%{
  kind: :bug,
  severity: 2.4,
  security: 0.03,
  confidence: %{kind: 0.91, severity: 0.62},
  probabilities: %{kind: %{bug: 0.93, feature: 0.04, other: 0.03}, severity: %{0 => 0.1, ...}},
  usage: %{input_tokens: 812, output_tokens: 0, cost: 3.4e-5},
  model: "jev-1.13.0"
}
```

`confidence`, `probabilities`, `usage`, and `model` are reserved question
names. `model` is the concrete model that answered, which differs from
`jev-latest` and is worth recording in evaluation runs.
