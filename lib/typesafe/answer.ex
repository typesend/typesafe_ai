defmodule TypeSafe.Answer do
  @moduledoc """
  Decodes one wire answer against the question that produced it, and turns
  any answer into a routing decision.

  Decoding needs the question (to know which type is expected, and — for
  Score — to supply the levels a label and index are read against) and the
  `TypeSafe.Keys` registry built for the request (to hand ids and Choice
  options back under the caller's own atoms or strings, never by calling
  `String.to_atom/1` on anything the API sent).

  `gate/2`, `yes?/2`, and `confidence/1` work the same way across all three
  answer types, so a caller who only cares about "should I trust this"
  doesn't need to branch on which question it was.
  """

  alias TypeSafe.Answer.{Choice, Noul, Score}
  alias TypeSafe.{Error, Keys, Question}

  @type t :: Noul.t() | Choice.t() | Score.t()

  @doc """
  Decodes one answer from the wire `answers` object.

  `wire_id` is the string key the answer was found under; `question` is the
  normalized question it answers. A `question`/`raw_answer` type mismatch, an
  unrecognized `"type"`, or a missing or invalid field all decode to an
  `Error.unexpected/2`.
  """
  @spec decode(map(), String.t(), Question.t(), Keys.t()) :: {:ok, t()} | {:error, Error.t()}
  def decode(%{"type" => type} = raw_answer, wire_id, %module{} = question, keys)
      when module in [Question.Noul, Question.Choice, Question.Score] do
    if type == module.wire_type() do
      decode_typed(module, raw_answer, wire_id, question, keys)
    else
      {:error,
       Error.unexpected(
         "answer #{inspect(wire_id)} does not match its question type: expected " <>
           "#{inspect(module.wire_type())}, got #{inspect(type)}",
         raw_answer
       )}
    end
  end

  def decode(%{} = raw_answer, wire_id, %module{}, _keys)
      when module in [Question.Noul, Question.Choice, Question.Score] do
    {:error,
     Error.unexpected(
       "answer #{inspect(wire_id)} has no \"type\"; expected #{inspect(module.wire_type())}",
       raw_answer
     )}
  end

  def decode(raw_answer, wire_id, _question, _keys) do
    {:error, Error.unexpected("answer #{inspect(wire_id)} must be a JSON object", raw_answer)}
  end

  defp decode_typed(Question.Noul, raw_answer, wire_id, _question, keys) do
    decode_noul(raw_answer, wire_id, keys)
  end

  defp decode_typed(Question.Choice, raw_answer, wire_id, _question, keys) do
    decode_choice(raw_answer, wire_id, keys)
  end

  defp decode_typed(Question.Score, raw_answer, wire_id, question, keys) do
    decode_score(raw_answer, wire_id, question, keys)
  end

  @doc """
  Routes an answer into `:act`, `:review`, or `:escalate` by comparing
  `confidence/1` against two thresholds.

  Both `:act` and `:review` are required. Raises `ArgumentError` if `:act` is
  lower than `:review`, since that would make the review band unreachable.
  """
  @spec gate(t(), keyword()) :: :act | :review | :escalate
  def gate(answer, opts) when is_list(opts) do
    act = Keyword.fetch!(opts, :act)
    review = Keyword.fetch!(opts, :review)

    if act < review do
      raise ArgumentError,
            "gate/2 requires act >= review, got act: #{inspect(act)}, review: #{inspect(review)}"
    end

    value = confidence(answer)

    cond do
      value >= act -> :act
      value >= review -> :review
      true -> :escalate
    end
  end

  @doc """
  Whether a Noul answer clears a probability threshold. Defaults to 0.5.

  Noul answers only. A Choice or Score answer has no yes/no reading, so it
  raises `FunctionClauseError` rather than inventing one; use `gate/2` or
  compare the fields you care about instead.
  """
  @spec yes?(Noul.t(), number()) :: boolean()
  def yes?(answer, threshold \\ 0.5)

  def yes?(%Noul{noul: noul}, threshold) when is_number(threshold) do
    noul >= threshold
  end

  @doc """
  The confidence value `gate/2` uses: `max(noul, 1 - noul)` for Noul, and the
  wire `confidence` for Choice and Score.

  The API returns no confidence for a Noul answer, only the probability, so
  the Noul value is this library's convention rather than something the model
  reported. It reads distance from 0.5 as certainty: 0.92 and 0.08 both give
  0.92, and 0.5 gives 0.5. That makes a Noul comparable to a Choice or Score
  in `gate/2`, but it is not the same measurement, so do not tune one
  threshold against numbers from the other.
  """
  @spec confidence(t()) :: float()
  def confidence(%Noul{noul: noul}), do: max(noul, 1 - noul)
  def confidence(%Choice{confidence: confidence}), do: confidence
  def confidence(%Score{confidence: confidence}), do: confidence

  defp decode_noul(%{"noul" => noul}, wire_id, keys) when is_number(noul) do
    {:ok, %Noul{id: Keys.id(keys, wire_id), noul: noul / 1}}
  end

  defp decode_noul(raw_answer, wire_id, _keys) do
    {:error, Error.unexpected("invalid noul answer for #{inspect(wire_id)}", raw_answer)}
  end

  defp decode_choice(
         %{"choice" => choice, "probabilities" => probabilities, "confidence" => confidence},
         wire_id,
         keys
       )
       when is_binary(choice) and is_map(probabilities) and is_number(confidence) do
    with {:ok, probabilities} <- decode_choice_probabilities(probabilities, wire_id, keys) do
      {:ok,
       %Choice{
         id: Keys.id(keys, wire_id),
         choice: Keys.option(keys, wire_id, choice),
         probabilities: probabilities,
         confidence: confidence / 1
       }}
    end
  end

  defp decode_choice(raw_answer, wire_id, _keys) do
    {:error, Error.unexpected("invalid choice answer for #{inspect(wire_id)}", raw_answer)}
  end

  defp decode_choice_probabilities(probabilities, wire_id, keys) do
    if Enum.all?(probabilities, fn {key, value} -> is_binary(key) and is_number(value) end) do
      decoded =
        Map.new(probabilities, fn {key, value} ->
          {Keys.option(keys, wire_id, key), value / 1}
        end)

      {:ok, decoded}
    else
      {:error,
       Error.unexpected("invalid choice probabilities for #{inspect(wire_id)}", probabilities)}
    end
  end

  defp decode_score(
         %{"score" => score, "probabilities" => raw_probabilities, "confidence" => confidence} =
           raw_answer,
         wire_id,
         %Question.Score{levels: question_levels},
         keys
       )
       when is_number(score) and is_map(raw_probabilities) and is_number(confidence) do
    with {:ok, probabilities} <- decode_integer_keyed(raw_probabilities, wire_id),
         {:ok, legend} <- decode_integer_keyed(Map.get(raw_answer, "legend", %{}), wire_id) do
      levels = score_levels(question_levels, probabilities)
      level = argmax_index(levels)
      winner = Enum.at(question_levels, level)

      {:ok,
       %Score{
         id: Keys.id(keys, wire_id),
         score: score / 1,
         level: level,
         label: Question.Score.label(winner),
         description: Question.Score.description(winner),
         levels: levels,
         probabilities: probabilities,
         legend: legend,
         confidence: confidence / 1
       }}
    end
  end

  defp decode_score(raw_answer, wire_id, _question, _keys) do
    {:error, Error.unexpected("invalid score answer for #{inspect(wire_id)}", raw_answer)}
  end

  # String keys ("0", "1", ...) parsed to their level index. Never
  # `String.to_atom/1`; anything that isn't a clean non-negative integer fails.
  defp decode_integer_keyed(map, wire_id) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Integer.parse(key) do
        {index, ""} when index >= 0 -> {:cont, {:ok, Map.put(acc, index, value)}}
        _invalid -> {:halt, {:error, integer_key_error(wire_id, key, map)}}
      end
    end)
  end

  defp decode_integer_keyed(other, wire_id) do
    {:error, integer_key_error(wire_id, other, other)}
  end

  defp integer_key_error(wire_id, key, body) do
    Error.unexpected("invalid level key #{inspect(key)} for #{inspect(wire_id)}", body)
  end

  defp score_levels(question_levels, probabilities) do
    question_levels
    |> Enum.with_index()
    |> Enum.map(fn {level, index} ->
      {Question.Score.label(level), Map.get(probabilities, index, 0.0)}
    end)
  end

  # Highest probability wins; a tie keeps the lowest index because later
  # levels only replace the leader on a strictly greater probability.
  defp argmax_index([{_label, first_probability} | _] = levels) do
    levels
    |> Enum.with_index()
    |> Enum.reduce({0, first_probability}, fn {{_label, probability}, index},
                                              {best_index, best_probability} ->
      if probability > best_probability,
        do: {index, probability},
        else: {best_index, best_probability}
    end)
    |> elem(0)
  end
end
