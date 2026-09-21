defmodule Jev.TestTest do
  use ExUnit.Case, async: true

  import Jev.Fixture, only: [questions: 0]

  doctest Jev.Test

  setup do
    Req.Test.set_req_test_to_private()
    %{questions: Jev.questions(questions())}
  end

  describe "body/2" do
    test "round-trips through Jev.reply/3", %{questions: questions} do
      given = %{
        kind: :feature,
        severity: 1.2,
        security: 0.8,
        confidence: %{kind: 0.4, severity: 0.7},
        probabilities: %{
          kind: %{bug: 0.3, feature: 0.6, other: 0.1},
          severity: %{1 => 0.8, 2 => 0.2}
        },
        model: "laya-421m",
        usage: %{input_tokens: 40, output_tokens: 0}
      }

      reply = given |> Jev.Test.body(questions()) |> Jev.reply(questions)

      assert Map.drop(reply, [:usage]) == Map.drop(given, [:usage])
      assert %{input_tokens: 40, output_tokens: 0} = reply.usage
    end

    test "fills in the distribution implied by the confidence", %{questions: questions} do
      reply =
        [kind: :bug, confidence: %{kind: 0.5}]
        |> Jev.Test.body(questions())
        |> Jev.reply(questions)

      assert reply.kind == :bug
      assert reply.confidence.kind == 0.5
      assert_in_delta reply.probabilities.kind.bug, 0.5 * (2 / 3) + 1 / 3, 1.0e-9
      assert_in_delta Enum.sum(Map.values(reply.probabilities.kind)), 1.0, 1.0e-9
      assert_in_delta Jev.confidence(reply.probabilities.kind), 0.5, 1.0e-9
    end

    test "defaults to certainty, a test model, zero usage, and a legend for scores" do
      body = Jev.Test.body([severity: 2.4], questions())

      assert body["model"] == "jev-test"
      assert body["usage"] == %{"input_tokens" => 0, "output_tokens" => 0}

      assert %{"type" => "score", "score" => 2.4, "confidence" => 1.0, "legend" => legend} =
               body["answers"]["severity"]

      assert legend == %{
               "0" => "Cosmetic",
               "1" => "Workaround",
               "2" => "Blocks",
               "3" => "Data loss"
             }

      assert body["answers"]["severity"]["probabilities"]["2"] == 1.0
      refute Map.has_key?(body["answers"], "kind")
    end

    test "emits what the API emits, with no null fields" do
      body = Jev.Test.body([security: 0.2], questions())
      assert body["answers"]["security"] == %{"type" => "noul", "noul" => 0.2}
    end

    test "accepts the wire questions of a request" do
      wire = %{"questions" => JSON.decode!(JSON.encode!(Jev.questions(questions())))}
      body = Jev.Test.body([kind: :other], wire)
      assert body["answers"]["kind"]["choice"] == "other"
    end

    test "rejects unknown questions, labels, and mismatched values" do
      assert_raise ArgumentError, ~r/no question named :mood/, fn ->
        Jev.Test.body([mood: :good], questions())
      end

      assert_raise ArgumentError, ~r/"wontfix" is not one of/, fn ->
        Jev.Test.body([kind: :wontfix], questions())
      end

      assert_raise ArgumentError, ~r/is not an answer to a :noul question/, fn ->
        Jev.Test.body([security: :yes], questions())
      end
    end
  end

  describe "respond/2 and error/3" do
    test "answers a Req.Test stub from the request's own questions" do
      Req.Test.stub(Jev.HTTP, fn conn ->
        {request, conn} = Jev.Test.request(conn)
        assert request["state"] == "a crash"
        Jev.Test.respond(conn, kind: :bug, security: 0.01, confidence: %{kind: 0.95})
      end)

      assert {:ok, %{kind: :bug, security: 0.01, confidence: %{kind: 0.95}}} =
               Jev.HTTP.post("a crash", questions())
    end

    test "sends an error the client turns into Jev.Error" do
      Req.Test.stub(Jev.HTTP, &Jev.Test.error(&1, 422, "criteria must have at least 2 options"))

      assert {:error, %Jev.Error{status: 422} = error} = Jev.HTTP.post("x", security: "Vuln?")
      assert Exception.message(error) =~ "criteria must have at least 2 options"
    end
  end
end
