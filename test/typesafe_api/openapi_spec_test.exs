defmodule TypeSafeAPI.OpenAPISpecTest do
  @moduledoc """
  Loads the vendored OpenAPI snapshot (`priv/openapi.json`) and asserts the
  facts our typed client relies on. If this test fails after refreshing the
  snapshot, the upstream API has drifted from what our client assumes: read
  the failure, decide whether it is a client bug or a contract change, and
  fix accordingly. See the "Refreshing the OpenAPI snapshot" section of
  DESIGN.md.
  """

  use ExUnit.Case, async: true

  alias TypeSafeAPI.Models
  alias TypeSafeAPI.Question.{Choice, Noul, Score}
  alias TypeSafeAPI.SystemOne

  setup_all do
    path = Path.join(:code.priv_dir(:typesafe_api), "openapi.json")
    spec = path |> File.read!() |> JSON.decode!()
    {:ok, spec: spec}
  end

  describe "paths" do
    test "exactly /v1/models (GET) and /v1/systemone (POST) are documented", %{spec: spec} do
      assert Map.keys(spec["paths"]) |> Enum.sort() == ["/v1/models", "/v1/systemone"]
      assert Map.keys(spec["paths"]["/v1/models"]) == ["get"]
      assert Map.keys(spec["paths"]["/v1/systemone"]) == ["post"]
    end

    test "both operations require bearer security", %{spec: spec} do
      assert spec["paths"]["/v1/models"]["get"]["security"] == [%{"HTTPBearer" => []}]
      assert spec["paths"]["/v1/systemone"]["post"]["security"] == [%{"HTTPBearer" => []}]
    end

    test "our path constants match the spec paths" do
      assert SystemOne.path() == "/v1/systemone"
      assert Models.path() == "/v1/models"
      assert Map.has_key?(spec_paths(), SystemOne.path())
      assert Map.has_key?(spec_paths(), Models.path())
    end

    defp spec_paths do
      path = Path.join(:code.priv_dir(:typesafe_api), "openapi.json")
      path |> File.read!() |> JSON.decode!() |> Map.fetch!("paths")
    end
  end

  describe "components.schemas required fields: questions" do
    test "instructions is optional on every question type (only `type` truly required)", %{
      spec: spec
    } do
      schemas = spec["components"]["schemas"]

      assert schemas["NoulQuestion"]["required"] == ["type"]
      assert schemas["ChoiceQuestion"]["required"] == ["criteria", "type"]
      assert schemas["ScoreQuestion"]["required"] == ["criteria", "type"]
    end

    test "ScoreQuestion.criteria has minItems 1", %{spec: spec} do
      assert spec["components"]["schemas"]["ScoreQuestion"]["properties"]["criteria"]["minItems"] ==
               1
    end

    test "SystemOneRequest.questions has minProperties 1 and required includes state, model, questions",
         %{spec: spec} do
      request = spec["components"]["schemas"]["SystemOneRequest"]

      assert request["properties"]["questions"]["minProperties"] == 1
      assert "state" in request["required"]
      assert "model" in request["required"]
      assert "questions" in request["required"]
    end
  end

  describe "components.schemas required fields: answers" do
    test "NoulAnswer required includes noul and type", %{spec: spec} do
      required = spec["components"]["schemas"]["NoulAnswer"]["required"]
      assert "noul" in required
      assert "type" in required
    end

    test "ChoiceAnswer required includes choice, confidence, probabilities, type", %{spec: spec} do
      required = spec["components"]["schemas"]["ChoiceAnswer"]["required"]
      assert "choice" in required
      assert "confidence" in required
      assert "probabilities" in required
      assert "type" in required
    end

    test "ScoreAnswer required includes score, confidence, legend, probabilities, type", %{
      spec: spec
    } do
      required = spec["components"]["schemas"]["ScoreAnswer"]["required"]
      assert "score" in required
      assert "confidence" in required
      assert "legend" in required
      assert "probabilities" in required
      assert "type" in required
    end

    test "Usage required is exactly input_tokens, output_tokens", %{spec: spec} do
      assert spec["components"]["schemas"]["Usage"]["required"] == [
               "input_tokens",
               "output_tokens"
             ]
    end

    test "ModelMetadata required includes name, description, release_date", %{spec: spec} do
      required = spec["components"]["schemas"]["ModelMetadata"]["required"]
      assert "name" in required
      assert "description" in required
      assert "release_date" in required
    end
  end

  describe "NoulCriteria" do
    test "has properties true and false", %{spec: spec} do
      properties = spec["components"]["schemas"]["NoulCriteria"]["properties"]
      assert Map.has_key?(properties, "true")
      assert Map.has_key?(properties, "false")
    end
  end

  describe "422 validation error shape" do
    test "both operations' 422 response references HTTPValidationError", %{spec: spec} do
      models_422 = spec["paths"]["/v1/models"]["get"]["responses"]["422"]
      systemone_422 = spec["paths"]["/v1/systemone"]["post"]["responses"]["422"]

      assert get_in(models_422, ["content", "application/json", "schema", "$ref"]) ==
               "#/components/schemas/HTTPValidationError"

      assert get_in(systemone_422, ["content", "application/json", "schema", "$ref"]) ==
               "#/components/schemas/HTTPValidationError"
    end

    test "HTTPValidationError.detail is an array of ValidationError {loc, msg, type}", %{
      spec: spec
    } do
      schemas = spec["components"]["schemas"]
      detail = schemas["HTTPValidationError"]["properties"]["detail"]

      assert detail["type"] == "array"
      assert detail["items"]["$ref"] == "#/components/schemas/ValidationError"

      validation_error_required = schemas["ValidationError"]["required"]
      assert "loc" in validation_error_required
      assert "msg" in validation_error_required
      assert "type" in validation_error_required
    end
  end

  describe "validators conform to spec" do
    # NoulQuestion.required == ["type"]: the spec makes `instructions` optional.
    # Our struct enforces the `:instructions` key at construction time, so we
    # build directly (bypassing TypeSafeAPI.noul/2) to simulate "instructions
    # omitted", the same way a caller who never set it would look on the wire.
    #
    # EXPECTED TO FAIL right now: our validator currently requires
    # `instructions` (see TypeSafeAPI.Question.validate_description/3, called
    # with allow_nil not set, i.e. false) even though the spec does not.
    # Another agent is concurrently making `instructions` optional; once that
    # lands, this assertion should pass unmodified. Each question type gets
    # its own test so a failure here is reported independently of the others.
    @tag :spec_conformance
    test "Noul with only `type` (no instructions) is accepted" do
      noul = %Noul{instructions: nil, criteria: nil}
      assert TypeSafeAPI.Question.validate(noul) == :ok
    end

    # ChoiceQuestion.required == ["criteria", "type"]: instructions is
    # optional, criteria (>= 2 options, per local policy) is supplied.
    @tag :spec_conformance
    test "Choice with only criteria (no instructions) is accepted" do
      choice = %Choice{instructions: nil, criteria: [a: "A", b: "B"]}
      assert TypeSafeAPI.Question.validate(choice) == :ok
    end

    # ScoreQuestion.required == ["criteria", "type"]: instructions is
    # optional, criteria (2 levels, satisfying both spec minItems: 1 and our
    # local 2..10 policy) is supplied.
    @tag :spec_conformance
    test "Score with only criteria (no instructions) is accepted" do
      score = %Score{instructions: nil, levels: ["Low", "High"]}
      assert TypeSafeAPI.Question.validate(score) == :ok
    end

    test "spec allows a 1-level Score; our validator is deliberately stricter (2..10)", %{
      spec: spec
    } do
      # ScoreQuestion.criteria has minItems: 1 per the spec (asserted above).
      # Our TypeSafeAPI.Question.Score enforces 2..10 levels as local policy,
      # observed against the live API (a 1-level "scale" is not meaningfully
      # a rating). We do NOT assert that our validator accepts a 1-level
      # Score; we only assert the spec's floor, to document that our floor is
      # intentionally stricter than the spec allows.
      assert spec["components"]["schemas"]["ScoreQuestion"]["properties"]["criteria"][
               "minItems"
             ] == 1
    end
  end
end
