defmodule TypeSafeAPI.DocTest do
  use ExUnit.Case, async: true

  setup :typesafe_stubs

  defp typesafe_stubs(context), do: TypeSafeAPI.Test.typesafe_stubs(context)

  doctest TypeSafeAPI
  doctest TypeSafeAPI.JSON.OrderedObject
end
