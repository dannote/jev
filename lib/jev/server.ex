defmodule Jev.Server do
  @moduledoc """
  A GenServer that talks to Jev by replying.

  Your module implements `c:init/1`, the usual `c:handle_call/3`,
  `c:handle_cast/2`, `c:handle_info/2`, `c:handle_continue/2`, and one new
  callback, `c:handle_answer/3`. From any callback, return

      {:reply, {tag, state, questions}, your_state}

  and the request is posted to Jev under `Jev.TaskSupervisor` without blocking
  the server. When Jev answers,

      handle_answer(reply | {:error, reason}, tag, your_state)

  is called. `tag` is any term and plays the role `from` plays in
  `c:handle_call/3`; passing `from` itself is the common case, and callers of
  `handle_call/3` are then answered with `GenServer.reply/2`.

  A server can have any number of requests in flight. Tags tell them apart.
  A crashed request arrives as `{:error, reason}` instead of taking the server
  down. Clause order in `handle_answer/3` is the routing:

      defmodule Triage do
        use Jev.Server

        def init(_), do: {:ok, %{}}

        def handle_call({:labels, issue}, from, s) do
          {:reply, {from, issue,
             kind: {"What kind of issue?", %{bug: nil, feature: nil, other: nil}},
             security: "Is this a vulnerability?"}, s}
        end

        def handle_answer(%{security: p}, from, s) when p > 0.5, do: done(from, [:security], s)
        def handle_answer(%{kind: k, confidence: %{kind: c}}, from, s) when c > 0.85, do: done(from, [k], s)
        def handle_answer(%{kind: k}, from, s), do: done(from, [k, :"needs-triage"], s)
        def handle_answer({:error, reason}, from, s), do: done(from, {:error, reason}, s)

        defp done(from, result, s) do
          GenServer.reply(from, result)
          {:noreply, s}
        end
      end

  Per-request options such as `model:` go in a fourth element, which means
  the questions need their own brackets:

      {:reply, {tag, state, [kind: {"Which?", %{a: nil, b: nil}}], [model: "jev-preview"]}, s}

  `endpoint:` picks a named server from `config :jev, endpoints:`, for a
  self-hosted model that speaks the same wire format. See `Jev.HTTP`.

  Built the way `GenStage` and `Agent` are built: this module owns the real
  GenServer callbacks and delegates to yours, so `:sys.get_state/1`, Observer,
  and every GenServer option keep working. `c:init/1` may return a timeout or
  `{:continue, term}` as usual, and `c:terminate/2` and `c:code_change/3` are
  delegated when defined. As with any GenServer, `terminate/2` runs on a
  supervisor shutdown only if the process traps exits.
  """

  use GenServer

  @typedoc "What every callback returns."
  @type reply ::
          {:reply, {tag :: term(), Jev.entry(), keyword() | map()}, state :: term()}
          | {:reply, {tag :: term(), Jev.entry(), keyword() | map(), [Jev.HTTP.option()]},
             state :: term()}
          | {:noreply, state :: term()}
          | {:noreply, state :: term(), timeout() | :hibernate | {:continue, term()}}
          | {:stop, reason :: term(), state :: term()}

  @callback init(arg :: term()) ::
              {:ok, state :: term()}
              | {:ok, state :: term(), timeout() | :hibernate | {:continue, term()}}
              | {:stop, reason :: term()}
              | :ignore
  @callback handle_answer(Jev.reply() | {:error, term()}, tag :: term(), state :: term()) ::
              reply()
  @callback handle_call(request :: term(), GenServer.from(), state :: term()) :: reply()
  @callback handle_cast(request :: term(), state :: term()) :: reply()
  @callback handle_info(message :: term(), state :: term()) :: reply()
  @callback handle_continue(continue :: term(), state :: term()) :: reply()
  @callback terminate(reason :: term(), state :: term()) :: term()
  @callback code_change(old_vsn :: term() | {:down, term()}, state :: term(), extra :: term()) ::
              {:ok, state :: term()} | {:error, term()}
  @optional_callbacks handle_call: 3,
                      handle_cast: 2,
                      handle_info: 2,
                      handle_continue: 2,
                      terminate: 2,
                      code_change: 3

  @doc """
  Adopts the behaviour and defines `child_spec/1`.

  Options are child spec overrides, as with `use GenServer`:

      use Jev.Server, restart: :temporary, shutdown: 10_000

  Default `handle_call/3`, `handle_cast/2`, and `handle_info/2` clauses behave
  like GenServer's: an unexpected call or cast stops the server with a clear
  error, and an unexpected message is logged and ignored.
  """
  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @behaviour Jev.Server

      def child_spec(arg) do
        default = %{id: __MODULE__, start: {Jev.Server, :start_link, [__MODULE__, arg]}}
        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end

      @doc false
      def handle_call(msg, _from, state) do
        # Same trick as GenServer, so Dialyzer accepts the non-local return.
        case :erlang.phash2(1, 1) do
          0 ->
            raise "attempted to call Jev.Server #{inspect(Jev.Server.process_name())} " <>
                    "but no handle_call/3 clause was provided"

          1 ->
            {:stop, {:bad_call, msg}, state}
        end
      end

      @doc false
      def handle_cast(msg, state) do
        case :erlang.phash2(1, 1) do
          0 ->
            raise "attempted to cast Jev.Server #{inspect(Jev.Server.process_name())} " <>
                    "but no handle_cast/2 clause was provided"

          1 ->
            {:stop, {:bad_cast, msg}, state}
        end
      end

      @doc false
      def handle_info(msg, state) do
        Jev.Server.log_unexpected(__MODULE__, msg)
        {:noreply, state}
      end

      defoverridable child_spec: 1, handle_call: 3, handle_cast: 2, handle_info: 2
    end
  end

  @doc false
  def process_name do
    case Process.info(self(), :registered_name) do
      {_, []} -> self()
      {_, name} -> name
    end
  end

  @doc false
  def log_unexpected(module, msg) do
    :logger.error(
      %{
        label: {GenServer, :no_handle_info},
        report: %{module: module, message: msg, name: process_name()}
      },
      %{
        domain: [:otp, :elixir],
        error_logger: %{tag: :error_msg},
        report_cb: &GenServer.format_report/1
      }
    )
  end

  @doc "Starts `module` as a `Jev.Server`. `opts` are `GenServer.start_link/3` options."
  @spec start_link(module(), term(), GenServer.options()) :: GenServer.on_start()
  def start_link(module, arg, opts \\ []) do
    GenServer.start_link(__MODULE__, {module, arg}, opts)
  end

  @impl GenServer
  def init({module, arg}) do
    case module.init(arg) do
      {:ok, inner} -> {:ok, wrap(module, inner)}
      {:ok, inner, extra} -> {:ok, wrap(module, inner), extra}
      other -> other
    end
  end

  defp wrap(module, inner), do: %{module: module, inner: inner, pending: %{}}

  @impl GenServer
  def handle_call(request, from, st) do
    st.module.handle_call(request, from, st.inner) |> route(st)
  end

  @impl GenServer
  def handle_cast(request, st) do
    st.module.handle_cast(request, st.inner) |> route(st)
  end

  @impl GenServer
  def handle_continue(continue, st) do
    st.module.handle_continue(continue, st.inner) |> route(st)
  end

  @impl GenServer
  def handle_info({ref, result}, %{pending: pending} = st) when is_map_key(pending, ref) do
    Process.demonitor(ref, [:flush])
    {tag, st} = pop_pending(st, ref)
    st.module.handle_answer(answer(result), tag, st.inner) |> route(st)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pending: pending} = st)
      when is_map_key(pending, ref) do
    {tag, st} = pop_pending(st, ref)
    st.module.handle_answer({:error, reason}, tag, st.inner) |> route(st)
  end

  def handle_info(message, st) do
    st.module.handle_info(message, st.inner) |> route(st)
  end

  @impl GenServer
  def terminate(reason, st) do
    if function_exported?(st.module, :terminate, 2), do: st.module.terminate(reason, st.inner)
  end

  @impl GenServer
  def code_change(old_vsn, st, extra) do
    if function_exported?(st.module, :code_change, 3) do
      with {:ok, inner} <- st.module.code_change(old_vsn, st.inner, extra) do
        {:ok, %{st | inner: inner}}
      end
    else
      {:ok, st}
    end
  end

  @impl GenServer
  def format_status(status), do: Map.update!(status, :state, & &1.inner)

  defp pop_pending(%{pending: pending} = st, ref) do
    {tag, pending} = Map.pop!(pending, ref)
    {tag, %{st | pending: pending}}
  end

  defp answer({:ok, reply}), do: reply
  defp answer({:error, _} = error), do: error

  # {:reply, ...} always means "send this to Jev".
  defp route({:reply, {tag, state, questions}, inner}, st),
    do: route({:reply, {tag, state, questions, []}, inner}, st)

  defp route({:reply, {tag, state, questions, opts}, inner}, st) do
    questions = Jev.questions(questions)
    opts = Keyword.put(opts, :tag, tag)

    task =
      Task.Supervisor.async_nolink(Jev.TaskSupervisor, Jev.HTTP, :post, [state, questions, opts])

    {:noreply, %{st | inner: inner, pending: Map.put(st.pending, task.ref, tag)}}
  end

  defp route({:noreply, inner}, st), do: {:noreply, %{st | inner: inner}}
  defp route({:noreply, inner, extra}, st), do: {:noreply, %{st | inner: inner}, extra}
  defp route({:stop, reason, inner}, st), do: {:stop, reason, %{st | inner: inner}}
end
