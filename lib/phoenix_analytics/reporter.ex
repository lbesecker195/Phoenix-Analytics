defmodule PhoenixAnalytics.Reporter do
  @moduledoc """
  Sends beacons without the request waiting for them.

  Analytics must never be why a page is slow, and must never be why a page
  fails. Everything here is therefore fire-and-forget: the plug hands over a
  payload and returns immediately, delivery happens in a supervised task, and a
  failure is counted and dropped rather than raised.

  Under load the queue is bounded. When more beacons arrive than can be
  delivered the newest are dropped, which keeps a slow endpoint from turning
  into unbounded memory growth in an application that merely installed this
  library.

  Telemetry is emitted as `[:phoenix_analytics, :beacon, :sent | :failed |
  :dropped]`, so a host application can alarm on losing visibility.
  """

  use GenServer

  require Logger

  alias PhoenixAnalytics.Config

  @default_max_inflight 50

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Queues a beacon for delivery. Always returns `:ok`."
  def report(server \\ __MODULE__, payload, request, %Config{} = config) do
    GenServer.cast(server, {:report, payload, request, config})
  catch
    # A reporter that is not running must not take the request down with it.
    :exit, _ -> :ok
  end

  @doc "Waits for in-flight deliveries to finish. Intended for tests."
  def flush(server \\ __MODULE__, timeout \\ 5_000) do
    GenServer.call(server, :flush, timeout)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       inflight: %{},
       max_inflight: Keyword.get(opts, :max_inflight, @default_max_inflight),
       waiting: []
     }}
  end

  @impl true
  def handle_cast({:report, payload, request, config}, state) do
    if map_size(state.inflight) >= state.max_inflight do
      :telemetry.execute([:phoenix_analytics, :beacon, :dropped], %{count: 1}, %{
        reason: :saturated
      })

      {:noreply, state}
    else
      task =
        Task.Supervisor.async_nolink(PhoenixAnalytics.TaskSupervisor, fn ->
          config.transport.deliver(payload, request, config)
        end)

      {:noreply, put_in(state.inflight[task.ref], true)}
    end
  end

  @impl true
  def handle_call(:flush, from, state) do
    if map_size(state.inflight) == 0 do
      {:reply, :ok, state}
    else
      {:noreply, %{state | waiting: [from | state.waiting]}}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case result do
      :ok ->
        :telemetry.execute([:phoenix_analytics, :beacon, :sent], %{count: 1}, %{})

      {:error, reason} ->
        :telemetry.execute([:phoenix_analytics, :beacon, :failed], %{count: 1}, %{reason: reason})
        Logger.debug("phoenix_analytics: beacon failed: #{inspect(reason)}")
    end

    {:noreply, state |> drop(ref) |> maybe_reply()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    :telemetry.execute([:phoenix_analytics, :beacon, :failed], %{count: 1}, %{reason: reason})
    {:noreply, state |> drop(ref) |> maybe_reply()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp drop(state, ref), do: %{state | inflight: Map.delete(state.inflight, ref)}

  defp maybe_reply(%{inflight: inflight, waiting: waiting} = state)
       when map_size(inflight) == 0 and waiting != [] do
    Enum.each(waiting, &GenServer.reply(&1, :ok))
    %{state | waiting: []}
  end

  defp maybe_reply(state), do: state
end
