defmodule TypeSafe.DocTest do
  use ExUnit.Case, async: true

  setup :typesafe_stubs

  defp typesafe_stubs(context), do: TypeSafe.Test.typesafe_stubs(context)

  doctest TypeSafe
  doctest TypeSafe.JSON.OrderedObject
end
