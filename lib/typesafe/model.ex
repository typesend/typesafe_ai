defmodule TypeSafe.Model do
  @moduledoc """
  A model available to the account, as listed by `TypeSafe.models/1`.

  `release_date` is a `DateTime` when the API returns an ISO 8601 datetime
  (which it does today), a `Date` for a bare date, otherwise the raw string,
  so a format change upstream degrades to a string instead of a failed call.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          release_date: DateTime.t() | Date.t() | String.t() | nil
        }

  @enforce_keys [:name]
  defstruct [:name, :description, :release_date]

  @doc "Decodes one entry of the `models` array."
  @spec decode(map()) :: {:ok, t()} | :error
  def decode(%{"name" => name} = raw) when is_binary(name) do
    {:ok,
     %__MODULE__{
       name: name,
       description: string_or_nil(raw["description"]),
       release_date: parse_date(raw["release_date"])
     }}
  end

  def decode(_raw), do: :error

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_), do: nil

  defp parse_date(value) when is_binary(value) do
    with {:error, _} <- DateTime.from_iso8601(value),
         {:error, _} <- Date.from_iso8601(value) do
      value
    else
      {:ok, %DateTime{} = datetime, _offset} -> datetime
      {:ok, %Date{} = date} -> date
    end
  end

  defp parse_date(_), do: nil
end
