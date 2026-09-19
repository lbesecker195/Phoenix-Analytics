defmodule PhoenixAnalytics.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: PhoenixAnalytics.TaskSupervisor},
      PhoenixAnalytics.Reporter
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: PhoenixAnalytics.Supervisor)
  end
end
