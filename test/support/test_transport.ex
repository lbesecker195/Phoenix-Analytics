defmodule PhoenixAnalytics.TestTransport do
  @moduledoc """
  Captures beacons instead of sending them, and hands them to the test process.
  """

  @behaviour PhoenixAnalytics.Transport

  @impl true
  def deliver(payload, request, _config) do
    case Application.get_env(:phoenix_analytics_middleware, :test_pid) do
      pid when is_pid(pid) -> send(pid, {:beacon, payload, request})
      _ -> :ok
    end

    :ok
  end
end
