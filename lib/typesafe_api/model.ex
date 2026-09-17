defmodule TypeSafeAPI.Model do
  @moduledoc """
  A model available to the account, as listed by `TypeSafeAPI.models/1`.

  `release_date` is a `Date`, because that is what the endpoint means: the
  OpenAPI schema describes it as "Model release date, formatted as YYYY-MM-DD",
  even though the live API sends a full ISO 8601 datetime today. A datetime is
  reduced to the calendar date it carries, without shifting it into UTC, so a
  model released on the 15th at 20:00-07:00 does not report the 16th. A value
  this library cannot parse as a date at all — the `"latest"` alias, say —
  leaves `release_date` `nil`.

  `release_date_raw` is the string exactly as it arrived, so nothing is lost to
  the normalization. `raw` is the whole entry, so a field this struct does not
  model yet (a context window, a deprecation date) is reachable without waiting
  for a release; this endpoint is reverse-engineered from the official Python
  SDK, so it is the most likely one to grow fields.

  `description` is required and non-nullable in the spec, but a non-string one
  degrades to `nil` here rather than failing the call. It stays in `raw`.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          release_date: Date.t() | nil,
          release_date_raw: String.t() | nil,
          raw: map()
        }

  @enforce_keys [:name, :raw]
  defstruct [:name, :description, :release_date, :release_date_raw, :raw]

  @doc """
  Decodes one entry of the `models` array.

  Only a string `name` is required; `TypeSafeAPI.Models.list/2` skips an entry
  that returns `:error` rather than failing the whole list.
  """
  @spec decode(term()) :: {:ok, t()} | :error
  def decode(%{"name" => name} = raw) when is_binary(name) do
    release_date_raw = string_or_nil(raw["release_date"])

    {:ok,
     %__MODULE__{
       name: name,
       description: string_or_nil(raw["description"]),
       release_date: parse_date(release_date_raw),
       release_date_raw: release_date_raw,
       raw: raw
     }}
  end

  def decode(_raw), do: :error

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_), do: nil

  # Takes the calendar date the string states. A datetime's date part is read
  # as written, never converted to UTC first: the offset would move the day.
  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> value |> String.split(["T", "t", " "], parts: 2) |> date_part()
    end
  end

  defp parse_date(_), do: nil

  defp date_part([date, _time]) do
    case Date.from_iso8601(date) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp date_part(_no_time_part), do: nil
end
