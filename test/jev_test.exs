defmodule JevTest do
  use ExUnit.Case, async: true

  doctest Jev

  describe "questions/1" do
    test "accepts a map as well as a keyword list" do
      assert %{urgent: %Jev.Noul{}} = Jev.questions(%{urgent: "Is this urgent?"})
    end

    test "a map is noul instructions" do
      instructions = %{field: "author", question: "Is `field` present?"}

      assert %{present: %Jev.Noul{instructions: ^instructions}} =
               Jev.questions(present: instructions)
    end

    test "structs pass through" do
      noul = %Jev.Noul{instructions: "Urgent?", criteria: %{true: "Blocked", false: "Fine"}}
      assert %{urgent: ^noul} = Jev.questions(urgent: noul)
    end

    test "rejects an empty list" do
      assert_raise ArgumentError, ~r/at least one/, fn -> Jev.questions([]) end
    end

    test "rejects reserved names" do
      assert_raise ArgumentError, ~r/reserved/, fn -> Jev.questions(usage: "Any?") end
      assert_raise ArgumentError, ~r/reserved/, fn -> Jev.questions(model: "Any?") end
    end

    test "rejects a choice with one option or non-atom labels" do
      assert_raise ArgumentError, ~r/2 to 255/, fn -> Jev.questions(k: {"Q?", %{only: nil}}) end

      assert_raise ArgumentError, ~r/atom-labelled/, fn ->
        Jev.questions(k: {"Q?", %{"a" => nil, "b" => nil}})
      end
    end

    test "rejects a score with one or eleven levels" do
      assert_raise ArgumentError, ~r/2 to 10/, fn -> Jev.questions(s: {"Q?", ["only"]}) end

      assert_raise ArgumentError, ~r/2 to 10/, fn ->
        Jev.questions(s: {"Q?", Enum.map(1..11, &to_string/1)})
      end
    end

    test "rejects unknown shapes" do
      assert_raise ArgumentError, ~r/unrecognized shape/, fn -> Jev.questions(x: 42) end
    end

    test "encodes to the wire format" do
      questions = Jev.questions(Jev.Fixture.questions())
      wire = questions |> JSON.encode!() |> JSON.decode!()

      assert wire["kind"] == %{
               "type" => "choice",
               "instructions" => "What kind of issue?",
               "criteria" => %{"bug" => "Broken", "feature" => "New behavior", "other" => nil}
             }

      assert wire["severity"]["type"] == "score"
      assert wire["severity"]["criteria"] == ["Cosmetic", "Workaround", "Blocks", "Data loss"]

      assert wire["security"] == %{
               "type" => "noul",
               "instructions" => "Is this a vulnerability?",
               "criteria" => nil
             }
    end
  end

  describe "reply/3" do
    setup do
      %{questions: Jev.questions(Jev.Fixture.questions())}
    end

    test "maps every answer type", %{questions: questions} do
      reply = Jev.reply(Jev.Fixture.body(), questions)

      assert reply.kind == :bug
      assert reply.severity == 2.4
      assert reply.security == 0.03
      assert reply.confidence == %{kind: 0.91, severity: 0.62}
      assert reply.probabilities.kind == %{bug: 0.93, feature: 0.04, other: 0.03}
      assert reply.probabilities.severity == %{0 => 0.1, 1 => 0.1, 2 => 0.2, 3 => 0.6}
      assert reply.usage == %{input_tokens: 812, output_tokens: 0, cost: 812 * 0.042 / 1_000_000}
      assert reply.model == "jev-1.13.0"
    end

    test "is a plain map that pattern matches", %{questions: questions} do
      assert %{kind: :bug, confidence: %{kind: c}} =
               Jev.reply(Jev.Fixture.body(), questions)

      assert c > 0.85
    end

    test "tolerates missing probabilities and usage", %{questions: questions} do
      body =
        Jev.Fixture.body(%{
          "kind" => %{"type" => "choice", "choice" => "other", "confidence" => 0.5}
        })
        |> Map.delete("usage")

      reply = Jev.reply(body, questions)
      assert reply.kind == :other
      assert reply.probabilities.kind == %{}
      assert reply.usage == %{input_tokens: 0, output_tokens: 0, cost: 0.0}
    end

    test "computes confidence from the probabilities when the server omits it",
         %{questions: questions} do
      body =
        Jev.Fixture.body(%{
          "kind" => %{
            "type" => "choice",
            "choice" => "bug",
            "probabilities" => %{"bug" => 0.93, "feature" => 0.04, "other" => 0.03}
          },
          "severity" => %{
            "type" => "score",
            "score" => 2.3,
            "probabilities" => %{"0" => 0.1, "1" => 0.1, "2" => 0.2, "3" => 0.6}
          }
        })

      %{confidence: %{kind: kind, severity: severity}} = Jev.reply(body, questions)
      assert_in_delta kind, (0.93 - 1 / 3) / (1 - 1 / 3), 1.0e-9
      assert_in_delta severity, (0.6 - 1 / 4) / (1 - 1 / 4), 1.0e-9
    end

    test "confidence is nil when neither it nor probabilities are sent", %{questions: questions} do
      body = Jev.Fixture.body(%{"kind" => %{"type" => "choice", "choice" => "bug"}})
      assert %{confidence: %{kind: nil}} = Jev.reply(body, questions)
    end

    test "prices usage at the given rate", %{questions: questions} do
      body = Jev.Fixture.body()
      assert Jev.reply(body, questions, usd_per_million_input: 0).usage.cost == 0
      assert Jev.reply(body, questions, usd_per_million_input: 1000).usage.cost == 0.812
    end

    test "accepts integers where the API documents numbers", %{questions: questions} do
      body =
        Jev.Fixture.body(%{
          "security" => %{"type" => "noul", "noul" => 1},
          "severity" => %{"type" => "score", "score" => 3, "probabilities" => %{"3" => 1}}
        })

      assert %{security: 1, severity: 3, confidence: %{severity: 1.0}} =
               Jev.reply(body, questions)
    end

    test "ignores fields it does not know", %{questions: questions} do
      body =
        Jev.Fixture.body(%{
          "security" => %{"type" => "noul", "noul" => 0.2, "act" => true, "latency_ms" => 12}
        })
        |> Map.put("request_id", "abc")

      assert %{security: 0.2} = Jev.reply(body, questions)
    end

    test "a body that does not fit the wire format is a JSONCodec.Error", %{questions: questions} do
      body = Jev.Fixture.body(%{"security" => %{"type" => "noul", "noul" => "high"}})

      error = assert_raise JSONCodec.Error, fn -> Jev.reply(body, questions) end
      assert %JSONCodec.Error{path: [:answers, "security", :noul], got: "high"} = error
      assert Exception.message(error) =~ "answers.security.noul"

      assert_raise JSONCodec.Error, ~r/missing_required_field/, fn ->
        Jev.reply(%{"model" => "x"}, questions)
      end

      assert_raise JSONCodec.Error, fn ->
        Jev.reply(Jev.Fixture.body(%{"kind" => %{"type" => "verdict"}}), questions)
      end
    end

    test "an answer of the wrong kind for its question raises", %{questions: questions} do
      body = Jev.Fixture.body(%{"kind" => %{"type" => "noul", "noul" => 0.5}})

      assert_raise ArgumentError, ~r/answer for :kind is :noul.*Jev.Choice/, fn ->
        Jev.reply(body, questions)
      end
    end

    test "takes an already decoded Jev.Wire.Response", %{questions: questions} do
      wire = Jev.Wire.Response.from_map!(Jev.Fixture.body())
      assert Jev.reply(wire, questions) == Jev.reply(Jev.Fixture.body(), questions)
    end

    test "never creates atoms from the response", %{questions: questions} do
      body =
        Jev.Fixture.body(%{"kind" => %{"type" => "choice", "choice" => "zzz_not_a_label"}})

      assert_raise KeyError, fn -> Jev.reply(body, questions) end
    end
  end

  describe "cost/2" do
    test "uses the configured price by default" do
      Application.put_env(:jev, :usd_per_million_input, 1.0)
      on_exit(fn -> Application.delete_env(:jev, :usd_per_million_input) end)
      assert Jev.cost(500_000) == 0.5
    end
  end
end
