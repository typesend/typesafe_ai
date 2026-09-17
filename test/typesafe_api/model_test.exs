defmodule TypeSafeAPI.ModelTest do
  use ExUnit.Case, async: true

  alias TypeSafeAPI.Model

  test "a bare date decodes to a Date and keeps the raw string" do
    assert {:ok, model} =
             Model.decode(%{
               "name" => "jev-1.13.0",
               "description" => "Flagship",
               "release_date" => "2026-03-01"
             })

    assert model.release_date == ~D[2026-03-01]
    assert model.release_date_raw == "2026-03-01"
    assert model.description == "Flagship"
  end

  test "a datetime decodes to its calendar date without shifting the offset" do
    assert {:ok, utc} =
             Model.decode(%{"name" => "a", "release_date" => "2026-09-10T18:39:06.057655+00:00"})

    assert utc.release_date == ~D[2026-09-10]

    assert {:ok, offset} =
             Model.decode(%{"name" => "b", "release_date" => "2026-09-15T20:00:00-07:00"})

    assert offset.release_date == ~D[2026-09-15]
    assert offset.release_date_raw == "2026-09-15T20:00:00-07:00"
  end

  test "an unparseable release date is nil, with the string kept" do
    assert {:ok, model} = Model.decode(%{"name" => "jev-latest", "release_date" => "latest"})

    assert model.release_date == nil
    assert model.release_date_raw == "latest"
  end

  test "a missing or non-string release date is nil on both fields" do
    assert {:ok, model} = Model.decode(%{"name" => "a"})
    assert model.release_date == nil
    assert model.release_date_raw == nil

    assert {:ok, model} = Model.decode(%{"name" => "a", "release_date" => 42})
    assert model.release_date_raw == nil
  end

  test "unknown fields stay reachable through raw" do
    entry = %{"name" => "a", "context_window" => 128_000, "deprecation_date" => "2027-01-01"}

    assert {:ok, model} = Model.decode(entry)
    assert model.raw == entry
    assert model.raw["context_window"] == 128_000
  end

  test "a non-string description degrades to nil but stays in raw" do
    assert {:ok, model} = Model.decode(%{"name" => "a", "description" => %{"text" => "hi"}})
    assert model.description == nil
    assert model.raw["description"] == %{"text" => "hi"}
  end

  test "an entry with no string name is an error" do
    assert :error = Model.decode(%{"description" => "no name"})
    assert :error = Model.decode(%{"name" => 42})
    assert :error = Model.decode("nope")
  end
end
