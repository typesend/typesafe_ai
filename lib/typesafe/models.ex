defmodule TypeSafe.Models do
  @moduledoc """
  The models endpoint: `GET /v1/models`.

  The path is not documented on the public API reference; it comes from the
  official Python SDK's constants (`MODELS_PATH = "/v1/models"`), and the
  response shape `{"models": [{"name", "description", "release_date"}]}` from
  its generated schema.
  """

  alias TypeSafe.{Client, Error, HTTP, Model}

  @path "/v1/models"

  @doc "The models endpoint path."
  @spec path() :: String.t()
  def path, do: @path

  @doc """
  Lists the models available to the account.

  Accepts the same per-call options as `TypeSafe.HTTP.get/3`.
  """
  @spec list(Client.t(), [HTTP.call_option()]) :: {:ok, [Model.t()]} | {:error, Error.t()}
  def list(%Client{} = client, opts \\ []) do
    with {:ok, body} <- HTTP.get(client, @path, opts) do
      decode(body)
    end
  end

  defp decode(%{"models" => models} = body) when is_list(models) do
    models
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case Model.decode(raw) do
        {:ok, model} ->
          {:cont, {:ok, [model | acc]}}

        :error ->
          {:halt, {:error, Error.unexpected("malformed model entry: #{inspect(raw)}", body)}}
      end
    end)
    |> case do
      {:ok, models} -> {:ok, Enum.reverse(models)}
      error -> error
    end
  end

  defp decode(body) do
    {:error, Error.unexpected("expected a \"models\" array in the response", body)}
  end
end
