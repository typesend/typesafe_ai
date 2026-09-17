defmodule TypeSafeAPI.Keys do
  @moduledoc """
  Request-side registry of caller-supplied keys, so answers come back under
  the keys you sent.

  JSON object keys are strings. Elixir callers usually prefer atoms
  (`dept: TypeSafeAPI.choice(...)`, `billing: "..."`). Converting response
  strings back with `String.to_atom/1` would let a hostile or buggy response
  grow the atom table, so this library never does that. Instead it records
  every question id and Choice option key *as given* before the request goes
  out, and looks the wire strings up in that record when decoding.

  Keys that were atoms come back as atoms. Keys that were strings come back
  as strings. A wire key this registry has never seen comes back as the string
  the API sent.
  """

  alias TypeSafeAPI.Question

  @typedoc "A caller-supplied key: an atom or a string."
  @type key :: atom() | String.t()

  @type t :: %__MODULE__{
          ids: %{String.t() => key()},
          options: %{String.t() => %{String.t() => key()}}
        }

  defstruct ids: %{}, options: %{}

  @doc """
  Records the question ids and Choice option keys of a normalized question list.

  Takes `[{id, question_struct}]` where `id` is an atom or string.
  """
  @spec build([{key(), Question.t()}]) :: t()
  def build(questions) when is_list(questions) do
    Enum.reduce(questions, %__MODULE__{}, fn {id, question}, keys ->
      wire_id = wire(id)

      %{
        keys
        | ids: Map.put(keys.ids, wire_id, id),
          options: Map.put(keys.options, wire_id, option_keys(question))
      }
    end)
  end

  @doc """
  Converts a caller key to its wire form. Atoms become strings; strings pass
  through. Anything else is an `ArgumentError`, since the API needs a string.
  """
  @spec wire(key()) :: String.t()
  def wire(key) when is_binary(key), do: key
  def wire(key) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)

  def wire(key) do
    raise ArgumentError, "expected an atom or string key, got: #{inspect(key)}"
  end

  @doc """
  Restores the caller's question id for a wire id. Unknown ids are returned
  as the wire string.
  """
  @spec id(t(), String.t()) :: key()
  def id(%__MODULE__{ids: ids}, wire_id) when is_binary(wire_id) do
    Map.get(ids, wire_id, wire_id)
  end

  @doc """
  Restores the caller's Choice option key for a wire option under a wire
  question id. Unknown options are returned as the wire string.
  """
  @spec option(t(), String.t(), String.t()) :: key()
  def option(%__MODULE__{options: options}, wire_id, wire_option)
      when is_binary(wire_id) and is_binary(wire_option) do
    options
    |> Map.get(wire_id, %{})
    |> Map.get(wire_option, wire_option)
  end

  @doc """
  Reads `key` (an atom) from a map that a caller may have keyed with atoms or
  strings. Returns `nil` for anything that is not a map.

  The atom key wins when both are present. A key whose value is `false` or
  `nil` is still a key that is present, so it is returned as-is rather than
  falling through to the string key.
  """
  @spec get(term(), atom()) :: term()
  def get(%{} = map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  def get(_not_a_map, _key), do: nil

  defp option_keys(%Question.Choice{criteria: criteria}) do
    Map.new(criteria, fn {key, _description} -> {wire(key), key} end)
  end

  defp option_keys(_question), do: %{}
end
