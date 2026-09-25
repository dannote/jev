defmodule Jev.TelemetryTest do
  use ExUnit.Case, async: true

  import Jev.Fixture, only: [questions: 0, reply: 0]

  setup do
    ref = make_ref()
    events = [[:jev, :request, :start], [:jev, :request, :stop], [:jev, :answer]]
    :telemetry.attach_many({__MODULE__, ref}, events, &__MODULE__.forward/4, {self(), ref})
    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    %{ref: ref, questions: Jev.questions(questions())}
  end

  def forward(event, measurements, metadata, {parent, ref}) do
    send(parent, {ref, event, measurements, metadata})
  end

  test "spans a plain ok result", %{ref: ref, questions: questions} do
    reply = Jev.reply(Jev.Fixture.body(), questions)

    assert {:ok, ^reply} =
             Jev.Telemetry.span("state", questions, %{backend: Canned, tag: 1}, fn ->
               {:ok, reply}
             end)

    # The handler is global and other modules run concurrently: match this span's own events.
    assert_receive {^ref, [:jev, :request, :start], _, %{backend: Canned, tag: 1} = start}
    assert %{state_hash: _} = start
    assert start.questions == %{kind: :choice, severity: :score, security: :noul}

    assert_receive {^ref, [:jev, :request, :stop], %{input_tokens: 812, cost: _},
                    %{backend: Canned, tag: 1} = stop}

    assert stop.confidence == reply.confidence
    refute Map.has_key?(stop, :status)

    assert_receive {^ref, [:jev, :answer], %{confidence: 0.91}, %{name: :kind, backend: Canned}}
  end

  test "merges stop metadata from a three-tuple", %{ref: ref, questions: questions} do
    reply = Jev.reply(Jev.Fixture.body(), questions)

    {:ok, _} =
      Jev.Telemetry.span("state", questions, %{}, fn ->
        {:ok, reply, %{status: 200, cached: true}}
      end)

    assert_receive {^ref, [:jev, :request, :stop], _, %{status: 200, cached: true}}
  end

  test "describes failures", %{ref: ref, questions: questions} do
    error = %Jev.Error{status: 429, request_id: "r1"}
    meta = %{tag: ref}
    assert {:error, ^error} = Jev.Telemetry.span("s", questions, meta, fn -> {:error, error} end)
    assert_receive {^ref, [:jev, :request, :stop], %{}, %{status: 429, request_id: "r1"}}

    assert {:error, :down} = Jev.Telemetry.span("s", questions, meta, fn -> {:error, :down} end)
    assert_receive {^ref, [:jev, :request, :stop], %{}, %{error: :down}}
    refute_receive {^ref, [:jev, :answer], _, %{tag: ^ref}}
  end

  test "a canned backend emits the same events as the transport", %{ref: ref, questions: qs} do
    {:ok, %{kind: :bug}} = Jev.Canned.post("s", qs, answers: reply(), tag: :t)
    assert_receive {^ref, [:jev, :request, :stop], %{input_tokens: 812}, %{backend: Jev.Canned}}
  end
end
