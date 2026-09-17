defmodule Jev.ServerTest do
  use ExUnit.Case, async: false

  import Jev.APIStub

  setup {Req.Test, :set_req_test_to_shared}

  defp choice(label, confidence) do
    %{
      "kind" => %{
        "type" => "choice",
        "choice" => label,
        "confidence" => confidence,
        "probabilities" => %{}
      }
    }
  end

  describe "Jev.Triage" do
    setup do
      pid = start_supervised!({Jev.Triage, []})
      %{pid: pid}
    end

    test "routes answers through handle_answer clauses", %{pid: pid} do
      Req.Test.stub(Jev.HTTP, fn conn ->
        {body, conn} = body(conn)

        overrides =
          case body["state"]["title"] do
            "leak" -> %{"security" => %{"type" => "noul", "noul" => 0.9}}
            "typo" -> choice("other", 0.7)
            "meh" -> choice("feature", 0.3)
            _ -> %{}
          end

        json(conn, 200, triage_body(overrides))
      end)

      assert GenServer.call(pid, {:labels, %{title: "crash"}}) == [:bug, :"priority:high"]
      assert GenServer.call(pid, {:labels, %{title: "leak"}}) == [:security]
      assert GenServer.call(pid, {:labels, %{title: "typo"}}) == [:other]
      assert GenServer.call(pid, {:labels, %{title: "meh"}}) == [:feature, :"needs-triage"]
    end

    test "keeps many requests in flight and matches each answer to its caller", %{pid: pid} do
      Req.Test.stub(Jev.HTTP, fn conn ->
        {body, conn} = body(conn)
        Process.sleep(Enum.random(1..20))
        json(conn, 200, triage_body(choice(body["state"]["kind"], 0.99)))
      end)

      tasks =
        for kind <- ~w(bug feature other bug other) do
          Task.async(fn -> {kind, GenServer.call(pid, {:labels, %{kind: kind}})} end)
        end

      for {kind, labels} <- Task.await_many(tasks) do
        expected = if kind == "bug", do: [:bug, :"priority:high"], else: [String.to_atom(kind)]
        assert labels == expected
      end

      assert %{pending: pending} = :sys.get_state(pid)
      assert pending == %{}
    end

    test "API errors arrive at handle_answer as {:error, %Jev.Error{}}", %{pid: pid} do
      Req.Test.stub(Jev.HTTP, &json(&1, 422, %{"error" => "bad"}))

      assert {:error, %Jev.Error{status: 422}} = GenServer.call(pid, {:labels, %{title: "x"}})
    end

    test "a crashed request arrives as {:error, reason} and the server survives", %{pid: pid} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {%Protocol.UndefinedError{}, _stack}} =
                   GenServer.call(pid, {:labels, make_ref()})
        end)

      assert log =~ "JSON.Encoder not implemented"
      assert Process.alive?(pid)
    end

    test "format_status shows the inner state, not the wrapper", %{pid: pid} do
      {:status, _, _, items} = :sys.get_status(pid)

      assert {~c"State", %{}} =
               items
               |> List.last()
               |> Keyword.get_values(:data)
               |> List.flatten()
               |> List.keyfind(~c"State", 0)

      refute inspect(items) =~ "pending"
    end
  end

  defmodule Cascade do
    @moduledoc false
    # Asks a broad question, then narrows if unsure. Recursion is a reply from handle_answer.
    use Jev.Server

    @impl true
    def init(reply_to), do: {:ok, %{reply_to: reply_to, asked: []}}

    @impl true
    def handle_cast({:classify, text}, s) do
      {:reply, {{:broad, text}, text, kind: {"Kind?", %{a: nil, b: nil, c: nil}}}, s}
    end

    @impl true
    def handle_answer(%{kind: k, confidence: %{kind: c}}, {:broad, text}, s) when c < 0.5 do
      s = %{s | asked: [:broad | s.asked]}
      send(s.reply_to, {:unsure, k})

      {:reply,
       {{:narrow, text}, text, [kind: {"Which?", %{a: nil, b: nil}}], [model: "jev-preview"]}, s}
    end

    def handle_answer(%{kind: k}, {stage, _text}, s) do
      send(s.reply_to, {:classified, stage, k})
      {:noreply, %{s | asked: [stage | s.asked]}}
    end

    @impl true
    def handle_info(:ping, s) do
      send(s.reply_to, :pong)
      {:noreply, s}
    end
  end

  test "handle_answer can reply again, with per-request options" do
    Req.Test.stub(Jev.HTTP, fn conn ->
      {body, conn} = body(conn)

      answer =
        case body["model"] do
          "jev-latest" -> %{"choice" => "c", "confidence" => 0.2}
          "jev-preview" -> %{"choice" => "a", "confidence" => 0.95}
        end

      json(conn, 200, %{
        "answers" => %{"kind" => Map.put(answer, "type", "choice")},
        "usage" => %{}
      })
    end)

    pid = start_supervised!({Cascade, self()})
    GenServer.cast(pid, {:classify, "hello"})

    assert_receive {:unsure, :c}
    assert_receive {:classified, :narrow, :a}
    assert :sys.get_state(pid).inner.asked == [:narrow, :broad]
  end

  test "ordinary messages reach handle_info and the default ignores them" do
    pid = start_supervised!({Cascade, self()})
    send(pid, :ping)
    assert_receive :pong

    triage = start_supervised!({Jev.Triage, []})
    send(triage, :unexpected)
    assert Process.alive?(triage)
  end

  test "child_spec starts the module through Jev.Server" do
    assert %{id: Jev.Triage, start: {Jev.Server, :start_link, [Jev.Triage, :arg]}} =
             Jev.Triage.child_spec(:arg)
  end
end
