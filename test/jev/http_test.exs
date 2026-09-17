defmodule Jev.HTTPTest do
  use ExUnit.Case, async: true

  import Jev.APIStub

  setup do
    Req.Test.set_req_test_to_private()
    :ok
  end

  test "posts the wire format with the bearer key and returns the reply map" do
    Req.Test.stub(Jev.HTTP, fn conn ->
      {body, conn} = body(conn)
      assert conn.request_path == "/v1/systemone"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
      assert body["model"] == "jev-latest"
      assert body["state"] == %{"title" => "crash on start"}
      assert body["questions"]["security"]["type"] == "noul"
      json(conn, 200, triage_body())
    end)

    assert {:ok, %{kind: :bug, security: 0.03, usage: %{input_tokens: 812}}} =
             Jev.HTTP.post(%{title: "crash on start"}, triage_questions())
  end

  test "per-call options override configuration" do
    Req.Test.stub(Jev.HTTP, fn conn ->
      {body, conn} = body(conn)
      assert body["model"] == "jev-preview"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer other-key"]
      json(conn, 200, triage_body())
    end)

    assert {:ok, _} =
             Jev.HTTP.post("state", triage_questions(),
               model: "jev-preview",
               api_key: "other-key"
             )
  end

  test "non-2xx responses become Jev.Error with the request id" do
    Req.Test.stub(Jev.HTTP, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-typesafe-request-id", "req-1")
      |> json(422, %{"error" => "criteria must have at least 2 options"})
    end)

    assert {:error, %Jev.Error{status: 422, request_id: "req-1"} = error} =
             Jev.HTTP.post("state", security: "Vuln?")

    assert error.body == %{"error" => "criteria must have at least 2 options"}
  end

  test "retries 429 and 529, then gives up" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(Jev.HTTP, fn conn ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})
      status = if rem(n, 2) == 0, do: 429, else: 529
      json(conn, status, %{"error" => "busy"})
    end)

    assert {:error, %Jev.Error{status: 529}} =
             Jev.HTTP.post("state", [security: "Vuln?"], max_retries: 3)

    assert Agent.get(counter, & &1) == 4
  end

  test "recovers when a retry succeeds" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(Jev.HTTP, fn conn ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> json(conn, 529, %{"error" => "overloaded"})
        _ -> json(conn, 200, triage_body())
      end
    end)

    assert {:ok, %{kind: :bug}} = Jev.HTTP.post("state", triage_questions())
  end

  test "transport errors are returned, not raised" do
    Req.Test.stub(Jev.HTTP, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %Req.TransportError{reason: :econnrefused}} =
             Jev.HTTP.post("state", [security: "Vuln?"], max_retries: 0)
  end

  test "a missing api key raises" do
    Application.put_env(:jev, :api_key, nil)
    on_exit(fn -> Application.put_env(:jev, :api_key, "test-key") end)
    System.delete_env("TYPESAFE_API_KEY")

    assert_raise ArgumentError, ~r/TYPESAFE_API_KEY/, fn ->
      Jev.HTTP.post("state", security: "Vuln?")
    end
  end

  describe "telemetry" do
    setup do
      ref = make_ref()

      events = [
        [:jev, :request, :start],
        [:jev, :request, :stop],
        [:jev, :request, :exception],
        [:jev, :answer]
      ]

      :telemetry.attach_many({__MODULE__, ref}, events, &__MODULE__.forward/4, {self(), ref})
      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
      %{ref: ref}
    end

    def forward(event, measurements, metadata, {parent, ref}) do
      send(parent, {ref, event, measurements, metadata})
    end

    test "spans the request with tokens and cost, and emits one event per answer", %{ref: ref} do
      Req.Test.stub(Jev.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-typesafe-request-id", "req_ok")
        |> json(200, triage_body())
      end)

      state = %{title: "x"}

      {:ok, _} = Jev.HTTP.post(state, triage_questions(), tag: {:issue, 7})

      assert_receive {^ref, [:jev, :request, :start], %{system_time: _}, start}
      assert start.tag == {:issue, 7}
      assert start.state_hash == :erlang.phash2(state)
      assert start.questions == %{kind: :choice, severity: :score, security: :noul}
      refute Map.has_key?(start, :state)

      assert_receive {^ref, [:jev, :request, :stop], stop_measurements, stop}
      assert %{duration: _, input_tokens: 812, output_tokens: 0, cost: cost} = stop_measurements
      assert cost == Jev.cost(812)
      assert stop.status == 200
      assert stop.request_id == "req_ok"
      assert stop.confidence == %{kind: 0.91, severity: 0.62}

      assert_receive {^ref, [:jev, :answer], %{confidence: 0.91, probability: 0.93},
                      %{name: :kind, type: :choice, answer: :bug}}

      assert_receive {^ref, [:jev, :answer], %{confidence: 0.62, probability: 0.6},
                      %{name: :severity, type: :score}}

      assert_receive {^ref, [:jev, :answer], %{probability: 0.03},
                      %{name: :security, type: :noul, answer: 0.03}}
    end

    test "stop metadata carries the status and request id on failure", %{ref: ref} do
      Req.Test.stub(Jev.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-typesafe-request-id", "req-9")
        |> json(401, %{"error" => "no"})
      end)

      {:error, _} = Jev.HTTP.post("state", security: "Vuln?")

      assert_receive {^ref, [:jev, :request, :stop], _, %{status: 401, request_id: "req-9"}}
      refute_receive {^ref, [:jev, :answer], _, _}
    end

    test "exceptions inside the call emit the exception event", %{ref: ref} do
      assert_raise Protocol.UndefinedError, fn ->
        Jev.HTTP.post(make_ref(), security: "Vuln?")
      end

      assert_receive {^ref, [:jev, :request, :exception], _, %{kind: :error}}
    end
  end
end
