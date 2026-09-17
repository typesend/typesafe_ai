defmodule TypeSafeAPI.Models do
  @moduledoc """
  The models endpoint: `GET /v1/models`.

  The path is not documented on the public API reference; it comes from the
  official Python SDK's constants (`MODELS_PATH = "/v1/models"`), and the
  response shape `{"models": [{"name", "description", "release_date"}]}` from
  its generated schema.

  Because the endpoint is undocumented, `list/2` is deliberately tolerant: an
  entry it cannot decode is logged at warning and skipped, and the models that
  did decode are returned. A list endpoint is the one place where one unfamiliar
  row should not cost you the other ten. Only a body with no `models` array at
  all is an error.
  """

  require Logger

  alias TypeSafeAPI.{Client, Error, HTTP, Model}

  @path "/v1/models"

  @schema NimbleOptions.new!(
            timeout: [type: :pos_integer, doc: "Timeout in milliseconds for this call."],
            retry: [
              type: TypeSafeAPI.Retry.option_type(),
              doc: "Retry policy for this call; see `TypeSafeAPI.Retry.new/1`."
            ],
            req_options: [type: :keyword_list, doc: "Extra `Req` options for this call."],
            telemetry: [type: :map, doc: "Extra metadata merged into telemetry events."]
          )

  @doc "The models endpoint path."
  @spec path() :: String.t()
  def path, do: @path

  @doc """
  Per-call options accepted by `list/2`.

  #{NimbleOptions.docs(@schema)}
  """
  @spec options_schema() :: NimbleOptions.t()
  def options_schema, do: @schema

  @doc """
  Lists the models available to the account.

  An unknown option is a `:validation` error and no request is sent, the same
  as for `TypeSafeAPI.evaluate/4`. An entry that fails to decode is logged and
  skipped; see the module doc.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """
  @spec list(Client.t(), keyword()) :: {:ok, [Model.t()]} | {:error, Error.t()}
  def list(%Client{} = client, opts \\ []) do
    with {:ok, opts} <- validate_options(opts),
         {:ok, body} <- HTTP.get(client, @path, opts) do
      decode(body)
    end
  end

  defp validate_options(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, opts} -> {:ok, opts}
      {:error, error} -> {:error, Error.validation(Exception.message(error))}
    end
  end

  defp decode(%{"models" => models}) when is_list(models) do
    {:ok, Enum.flat_map(models, &decode_entry/1)}
  end

  defp decode(body) do
    {:error, Error.unexpected("expected a \"models\" array in the response", body)}
  end

  defp decode_entry(raw) do
    case Model.decode(raw) do
      {:ok, model} ->
        [model]

      :error ->
        Logger.warning("TypeSafeAPI: skipping a model entry it could not decode: #{inspect(raw)}")

        []
    end
  end
end
