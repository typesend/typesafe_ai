defmodule Mix.Tasks.SupportTriage.Demo do
  @shortdoc "Triages a few sample support messages"

  @moduledoc """
  Triages a few sample support messages and prints the decisions.

      mix support_triage.demo

  Uses the live API when `TYPESAFE_API_KEY` is set and `TypeSafeAPI.Test` stubs
  otherwise. The first line of output says which.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    SupportTriage.Demo.run()
  end
end
