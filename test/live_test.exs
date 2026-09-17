defmodule TypeSafe.LiveTest do
  @moduledoc """
  Hits the real API. Excluded by default; run with:

      TYPESAFE_API_KEY=sk-... TYPESAFE_LIVE_TESTS=1 mix test --include live
  """

  use ExUnit.Case, async: false

  @moduletag :live

  @enabled System.get_env("TYPESAFE_LIVE_TESTS") == "1" and
             System.get_env("TYPESAFE_API_KEY") not in [nil, ""]

  if not @enabled do
    @moduletag skip: "set TYPESAFE_API_KEY and TYPESAFE_LIVE_TESTS=1 to run live tests"
  end

  setup_all do
    %{client: TypeSafe.new()}
  end

  test "evaluates the README example against the live API", %{client: client} do
    {:ok, result} =
      TypeSafe.evaluate(client, "Help! My payouts have been failing for 3 days.",
        urgent: TypeSafe.noul("Does this convey urgency?"),
        dept:
          TypeSafe.choice("Which team should handle this?",
            billing: "Payments, invoicing, refunds",
            technical: "Bugs, outages, integrations",
            sales: nil
          ),
        anger:
          TypeSafe.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
      )

    assert is_binary(result.model)
    assert result.answers.urgent.noul >= 0 and result.answers.urgent.noul <= 1
    assert result.answers.dept.choice in [:billing, :technical, :sales]
    assert_in_delta Enum.sum(Map.values(result.answers.dept.probabilities)), 1.0, 0.01
    assert result.answers.anger.level in 0..2
    assert result.answers.anger.label in ["Calm", "Frustrated", "Very angry"]
    assert is_integer(result.usage.input_tokens)
  end

  test "lists models", %{client: client} do
    assert {:ok, [%TypeSafe.Model{name: name} | _]} = TypeSafe.models(client)
    assert is_binary(name)
  end
end
