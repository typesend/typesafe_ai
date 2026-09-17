defmodule TypeSafeAPI.Application do
  @moduledoc """
  Starts the one process this library owns: a `Task.Supervisor` named
  `TypeSafeAPI.TaskSupervisor`, used by `TypeSafeAPI.FanOut`.

  It exists so fan-out tasks are supervised rather than linked to the caller.
  A task that raises then comes back as one failed outcome instead of taking
  the calling process down with it. Nothing else runs here, and nothing else
  in the library needs the application to be started.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [{Task.Supervisor, name: TypeSafeAPI.TaskSupervisor}]
    Supervisor.start_link(children, strategy: :one_for_one, name: TypeSafeAPI.Supervisor)
  end
end
