defmodule Jev.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Jev.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Jev.Supervisor)
  end
end
