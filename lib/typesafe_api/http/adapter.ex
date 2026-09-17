defmodule TypeSafeAPI.HTTP.Adapter do
  @moduledoc false
  # Wraps whatever adapter the request ended up with, for one reason: a Finch
  # connection-pool checkout timeout *raises*.
  #
  # `Finch.HTTP1.Pool` catches the `NimblePool` checkout exit and reraises a
  # bare `RuntimeError` ("Finch was unable to provide a connection within the
  # timeout due to excess queuing for connections..."). It is not a
  # `Finch.Error`, so `Req` never normalizes it, no error step ever sees it,
  # and it escapes `Req.Request.run_request/1` as an exception. For this
  # library that means the one promise it makes - every failure comes back as
  # `{:error, %TypeSafeAPI.Error{}}` - breaks exactly when the pool is
  # saturated, which is when callers are least able to cope with a raise.
  #
  # Turning it into `%Req.HTTPError{reason: :pool_timeout}` puts it back on the
  # normal path: the retry step gets a say (and always retries it, since
  # nothing was sent), and it maps to a `:timeout` error.
  #
  # Matching on the message is unpleasant and tied to Finch's wording; the
  # alternative is letting the raise through, which is worse. Should Finch
  # start returning a `%Finch.Error{reason: :pool_timeout}` instead, `Req` will
  # hand us the same `%Req.HTTPError{}` and this clause simply stops firing.

  @private_key :typesafe_wrapped_adapter
  @pool_message "unable to provide a connection"

  @doc false
  @spec wrap(Req.Request.t()) :: Req.Request.t()
  def wrap(%Req.Request{adapter: __MODULE__} = request), do: request

  def wrap(%Req.Request{adapter: adapter} = request) do
    request
    |> Req.Request.put_private(@private_key, adapter)
    |> Map.put(:adapter, __MODULE__)
  end

  @doc false
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{} = request) do
    wrapped = Req.Request.get_private(request, @private_key, Req.Finch)
    run_wrapped(wrapped, request)
  rescue
    error in RuntimeError ->
      if pool_checkout_timeout?(error) do
        {request, %Req.HTTPError{protocol: :http1, reason: :pool_timeout}}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp run_wrapped(module, request) when is_atom(module), do: module.run(request)
  defp run_wrapped(fun, request) when is_function(fun, 1), do: fun.(request)

  defp pool_checkout_timeout?(%RuntimeError{message: message}) when is_binary(message) do
    String.contains?(message, @pool_message) and String.contains?(message, "Finch")
  end

  defp pool_checkout_timeout?(_error), do: false
end
