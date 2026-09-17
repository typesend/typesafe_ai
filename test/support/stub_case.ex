defmodule TypeSafeAPI.StubCase do
  @moduledoc """
  Test support: builds clients routed through `Req.Test` and a fake clock so
  retry tests never sleep for real.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import TypeSafeAPI.StubCase
      import Plug.Conn, only: [send_resp: 3, put_resp_header: 3, get_req_header: 2]
    end
  end

  setup context do
    Req.Test.set_req_test_from_context(context)
    :ok
  end

  @stub_name TypeSafeAPI.StubCase

  @doc "The `Req.Test` stub name used by `client/1`."
  def stub_name, do: @stub_name

  @doc "A client whose requests go to the `Req.Test` stub named `stub_name/0`."
  def client(opts \\ []), do: TypeSafeAPI.Test.client([name: @stub_name] ++ opts)

  @doc "Registers a stub plug function for the current test."
  def stub(fun) when is_function(fun, 1), do: Req.Test.stub(@stub_name, fun)

  @doc "A stub that replies with the given responses in order, then repeats the last one."
  def stub_sequence(responses) when is_list(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    stub(fn conn ->
      response =
        Agent.get_and_update(agent, fn
          [last] -> {last, [last]}
          [next | rest] -> {next, rest}
        end)

      response.(conn)
    end)
  end

  @doc "Builds a stub reply function for a JSON response."
  def json(status, body, headers \\ []), do: &TypeSafeAPI.Test.json(&1, status, body, headers)

  @doc "Builds a stub reply function that simulates a transport error."
  def transport_error(reason), do: &Req.Test.transport_error(&1, reason)

  @doc """
  A fake clock for retry tests. `sleep` advances time instead of blocking and
  reports each sleep to the test process as `{:slept, ms}`.
  """
  def fake_clock do
    test_pid = self()
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    [
      clock_fun: fn -> Agent.get(agent, & &1) end,
      sleep_fun: fn ms ->
        Agent.update(agent, &(&1 + ms))
        send(test_pid, {:slept, ms})
        :ok
      end
    ]
  end

  @doc "Collects every `{:slept, ms}` message currently in the mailbox."
  def sleeps do
    receive do
      {:slept, ms} -> [ms | sleeps()]
    after
      0 -> []
    end
  end
end
