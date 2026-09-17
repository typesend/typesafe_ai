defmodule TypeSafeAPI.Answer do
  @moduledoc """
  Decodes one wire answer against the question that produced it, and turns
  any answer into a routing decision.

  Decoding needs the question (to know which type is expected, and to check the
  answer against the options or levels that were actually sent) and the
  `TypeSafeAPI.Keys` registry built for the request (to hand ids and Choice
  options back under the caller's own atoms or strings, never by calling
  `String.to_atom/1` on anything the API sent).

  Decoding is strict: a probability that is not a number, an option or level
  the caller never sent, a Noul outside `0.0..1.0`, or a `choice` that is not
  the highest-probability option all decode to an `Error.unexpected/2` rather
  than to a struct that is confidently wrong. The typed layer exists to catch
  exactly these, and `TypeSafeAPI.Result`'s `raw` still holds the response as
  it arrived.

  `gate/2` and `confidence/1` work the same way across all three answer types,
  so a caller who only cares about "should I trust this" doesn't need to branch
  on which question it was. `yes?/2` is Noul-only: a Choice or Score has no
  yes/no reading.
  """

  alias TypeSafeAPI.Answer.{Choice, Noul, Score}
  alias TypeSafeAPI.{Error, Keys, Question}

  @type t :: Noul.t() | Choice.t() | Score.t()

  @doc """
  Decodes one answer from the wire `answers` object.

  `wire_id` is the string key the answer was found under; `question` is the
  normalized question it answers. A `question`/`raw_answer` type mismatch, an
  unrecognized `"type"`, a missing or invalid field, or a value that disagrees
  with the question all decode to an `Error.unexpected/2`.
  """
  @spec decode(map(), String.t(), Question.t(), Keys.t()) :: {:ok, t()} | {:error, Error.t()}
  def decode(%{"type" => type} = raw_answer, wire_id, %module{} = question, keys)
      when module in [Question.Noul, Question.Choice, Question.Score] do
    if type == module.wire_type() do
      decode_typed(raw_answer, wire_id, question, keys)
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

  def decode(%{} = raw_answer, wire_id, question, _keys) do
    {:error,
     Error.unexpected(
       "answer #{inspect(wire_id)} was asked as #{inspect(question)}, which is not a " <>
         "TypeSafeAPI question struct",
       raw_answer
     )}
  end

  def decode(raw_answer, wire_id, _question, _keys) do
    {:error, Error.unexpected("answer #{inspect(wire_id)} must be a JSON object", raw_answer)}
  end

  defp decode_typed(raw_answer, wire_id, %Question.Noul{}, keys) do
    decode_noul(raw_answer, wire_id, keys)
  end

  defp decode_typed(raw_answer, wire_id, %Question.Choice{} = question, keys) do
    decode_choice(raw_answer, wire_id, question, keys)
  end

  defp decode_typed(raw_answer, wire_id, %Question.Score{} = question, keys) do
    decode_score(raw_answer, wire_id, question, keys)
  end

  @doc """
  Routes an answer into `:act`, `:review`, or `:escalate` by comparing
  `confidence/1` against two thresholds.

  Both `:act` and `:review` are required. Raises `ArgumentError` if `:act` is
  lower than `:review`, since that would make the review band unreachable.

  A Noul answer's confidence is `max(noul, 1 - noul)`, which has a floor of
  0.5, so `:escalate` is unreachable for a Noul unless `:review` is above 0.5.
  Rather than silently never escalating, `gate/2` raises `ArgumentError` when a
  Noul answer is given a `:review` threshold of 0.5 or lower. A Noul sitting at
  0.5 is the most uncertain answer the model can give, so the useful escalation
  threshold is just above it (`review: 0.55`, say). Choice and Score
  confidences come from the API and can be anything in `0.0..1.0`, so they take
  any thresholds.
  """
  @spec gate(t(), keyword()) :: :act | :review | :escalate
  def gate(answer, opts) when is_list(opts) do
    act = Keyword.fetch!(opts, :act)
    review = Keyword.fetch!(opts, :review)

    if act < review do
      raise ArgumentError,
            "gate/2 requires act >= review, got act: #{inspect(act)}, review: #{inspect(review)}"
    end

    check_noul_review!(answer, review)

    value = confidence(answer)

    cond do
      value >= act -> :act
      value >= review -> :review
      true -> :escalate
    end
  end

  defp check_noul_review!(%Noul{}, review) when is_number(review) and review <= 0.5 do
    raise ArgumentError,
          "gate/2 was given review: #{inspect(review)} for a Noul answer, whose confidence is " <>
            "max(noul, 1 - noul) and so is never below 0.5: :escalate could never be returned. " <>
            "Use a review threshold above 0.5, or yes?/2 if you want the yes/no reading."
  end

  defp check_noul_review!(_answer, _review), do: :ok

  @doc """
  Whether a Noul answer clears a probability threshold. Defaults to 0.5.

  Noul answers only. A Choice or Score answer has no yes/no reading, so this
  raises `ArgumentError` rather than inventing one; use `gate/2` to route on
  confidence, or compare the fields you care about instead.
  """
  @spec yes?(Noul.t(), number()) :: boolean()
  def yes?(answer, threshold \\ 0.5)

  def yes?(%Noul{noul: noul}, threshold) when is_number(threshold) do
    noul >= threshold
  end

  def yes?(%Noul{}, threshold) do
    raise ArgumentError, "yes?/2 needs a number as its threshold, got: #{inspect(threshold)}"
  end

  def yes?(%module{}, _threshold) when module in [Choice, Score] do
    raise ArgumentError,
          "yes?/2 is only defined for a Noul answer, got a #{inspect(module)}. " <>
            "A #{inspect(module)} answer has no yes/no reading: use gate/2 to route on " <>
            "confidence/1, or read its own fields."
  end

  @doc """
  The confidence value `gate/2` uses: `max(noul, 1 - noul)` for Noul, and the
  wire `confidence` for Choice and Score.

  The API returns no confidence for a Noul answer, only the probability, so
  the Noul value is this library's convention rather than something the model
  reported. It reads distance from 0.5 as certainty: 0.92 and 0.08 both give
  0.92, and 0.5 gives 0.5. That makes a Noul comparable to a Choice or Score
  in `gate/2`, but it is not the same measurement, so do not tune one
  threshold against numbers from the other. It is also the `confidence` field
  on `TypeSafeAPI.Answer.Noul`, so all three answer structs have the same shape.
  """
  @spec confidence(t()) :: float()
  def confidence(%Noul{confidence: confidence}), do: confidence
  def confidence(%Choice{confidence: confidence}), do: confidence
  def confidence(%Score{confidence: confidence}), do: confidence

  # -- Noul --------------------------------------------------------------------

  defp decode_noul(%{"noul" => noul} = raw_answer, wire_id, keys) when is_number(noul) do
    if noul >= 0 and noul <= 1 do
      value = noul / 1
      {:ok, %Noul{id: Keys.id(keys, wire_id), noul: value, confidence: max(value, 1.0 - value)}}
    else
      {:error,
       Error.unexpected(
         "noul answer for #{inspect(wire_id)} is #{inspect(noul)}, outside 0.0..1.0",
         raw_answer
       )}
    end
  end

  defp decode_noul(raw_answer, wire_id, _keys) do
    {:error, Error.unexpected("invalid noul answer for #{inspect(wire_id)}", raw_answer)}
  end

  # -- Choice ------------------------------------------------------------------

  defp decode_choice(
         %{"choice" => choice, "probabilities" => probabilities, "confidence" => confidence} =
           raw_answer,
         wire_id,
         %Question.Choice{criteria: criteria},
         keys
       )
       when is_binary(choice) and is_map(probabilities) and is_number(confidence) do
    with {:ok, decoded} <- decode_choice_probabilities(probabilities, wire_id, criteria),
         {:ok, option} <- fetch_choice_option(choice, wire_id, criteria, raw_answer),
         :ok <- check_choice_argmax(option, decoded, wire_id, raw_answer) do
      {:ok,
       %Choice{
         id: Keys.id(keys, wire_id),
         choice: option,
         description: option_description(criteria, option),
         probabilities: Map.new(decoded),
         options: decoded,
         confidence: confidence / 1
       }}
    end
  end

  defp decode_choice(raw_answer, wire_id, _question, _keys) do
    {:error, Error.unexpected("invalid choice answer for #{inspect(wire_id)}", raw_answer)}
  end

  # Returns the question's options in question order, each paired with its
  # probability: 0.0 for one the response left out. A wire key the question
  # never declared is an error, the same signal as an undeclared `choice`.
  #
  # The keys come from the question's own criteria rather than through
  # `Keys.option/3`, because the criteria already hold exactly what the caller
  # wrote — the registry exists for wire strings, and every key here is one the
  # caller declared. That also means `choice` and the `probabilities` keys can
  # never disagree about an option's identity.
  defp decode_choice_probabilities(probabilities, wire_id, criteria) do
    declared = Map.new(criteria, fn {key, _description} -> {Keys.wire(key), key} end)

    with :ok <- check_choice_values(probabilities, wire_id),
         :ok <- check_choice_keys(probabilities, wire_id, declared) do
      options =
        Enum.map(criteria, fn {key, _description} ->
          {key, probabilities |> Map.get(Keys.wire(key), 0.0) |> Kernel./(1)}
        end)

      {:ok, options}
    end
  end

  # An empty object would give every option 0.0, and the reported choice would
  # then tie for the argmax and pass every check below — the Choice twin of an
  # empty Score distribution reading as level 0.
  defp check_choice_values(probabilities, wire_id) when probabilities == %{} do
    {:error,
     Error.unexpected(
       "choice answer for #{inspect(wire_id)} has empty probabilities, so nothing supports the " <>
         "option it reports",
       probabilities
     )}
  end

  defp check_choice_values(probabilities, wire_id) do
    Enum.find(probabilities, fn {key, value} -> not (is_binary(key) and is_number(value)) end)
    |> case do
      nil ->
        :ok

      {key, value} ->
        {:error,
         Error.unexpected(
           "invalid choice probabilities for #{inspect(wire_id)}: option #{inspect(key)} is " <>
             "#{inspect(value)}, not a number",
           probabilities
         )}
    end
  end

  defp check_choice_keys(probabilities, wire_id, declared) do
    probabilities
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(declared, &1))
    |> case do
      [] ->
        :ok

      [unknown | _] ->
        {:error,
         Error.unexpected(
           "choice answer for #{inspect(wire_id)} gives a probability for " <>
             "#{inspect(unknown)}, which is not one of the options sent: " <>
             "#{inspect(Map.keys(declared))}",
           probabilities
         )}
    end
  end

  defp fetch_choice_option(choice, wire_id, criteria, raw_answer) do
    Enum.find(criteria, fn {key, _description} -> Keys.wire(key) == choice end)
    |> case do
      {key, _description} ->
        {:ok, key}

      nil ->
        {:error,
         Error.unexpected(
           "choice answer for #{inspect(wire_id)} picked #{inspect(choice)}, which is not one " <>
             "of the options sent: #{inspect(Enum.map(criteria, fn {key, _} -> key end))}",
           raw_answer
         )}
    end
  end

  # The API documents `choice` as the option with the highest probability, so a
  # disagreement means the two halves of the answer describe different things.
  # A tie that includes the reported choice is fine.
  defp check_choice_argmax(option, options, wire_id, raw_answer) do
    {_key, chosen} = Enum.find(options, fn {key, _probability} -> key == option end)
    {winner, best} = Enum.max_by(options, fn {_key, probability} -> probability end)

    if chosen >= best do
      :ok
    else
      {:error,
       Error.unexpected(
         "choice answer for #{inspect(wire_id)} picked #{inspect(option)} at " <>
           "#{inspect(chosen)}, but #{inspect(winner)} has the highest probability " <>
           "#{inspect(best)}",
         raw_answer
       )}
    end
  end

  defp option_description(criteria, option) do
    Enum.find_value(criteria, fn {key, description} -> key == option && description end) || nil
  end

  # -- Score -------------------------------------------------------------------

  defp decode_score(
         %{"score" => score, "probabilities" => raw_probabilities, "confidence" => confidence} =
           raw_answer,
         wire_id,
         %Question.Score{levels: question_levels},
         keys
       )
       when is_number(score) and is_map(raw_probabilities) and is_number(confidence) do
    count = length(question_levels)

    with {:ok, probabilities} <- decode_probabilities(raw_probabilities, wire_id, count),
         {:ok, legend} <- decode_legend(Map.get(raw_answer, "legend"), wire_id, question_levels) do
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

  defp decode_probabilities(raw_probabilities, wire_id, _count) when raw_probabilities == %{} do
    {:error,
     Error.unexpected(
       "score answer for #{inspect(wire_id)} has empty probabilities, so no level can be read " <>
         "from it",
       raw_probabilities
     )}
  end

  defp decode_probabilities(raw_probabilities, wire_id, count) do
    with {:ok, probabilities} <- decode_integer_keyed(raw_probabilities, wire_id, count) do
      probabilities
      |> Enum.find(fn {_index, value} -> not is_number(value) end)
      |> case do
        nil ->
          {:ok, Map.new(probabilities, fn {index, value} -> {index, value / 1} end)}

        {index, value} ->
          {:error,
           Error.unexpected(
             "invalid score probabilities for #{inspect(wire_id)}: level #{index} is " <>
               "#{inspect(value)}, not a number",
             raw_probabilities
           )}
      end
    end
  end

  # `legend` is required by the spec, but a missing or null one is not worth
  # failing a complete set of answers over: `label` comes from the question.
  defp decode_legend(nil, _wire_id, _question_levels), do: {:ok, %{}}

  defp decode_legend(raw_legend, wire_id, question_levels) do
    with {:ok, legend} <- decode_integer_keyed(raw_legend, wire_id, length(question_levels)),
         :ok <- check_legend(legend, wire_id, question_levels, raw_legend) do
      {:ok, legend}
    end
  end

  # The legend is the API's copy of the levels that were sent, so a label that
  # disagrees means `label` would describe a different scale from the one the
  # model was shown.
  defp check_legend(legend, wire_id, question_levels, raw_legend) do
    legend
    |> Enum.sort()
    |> Enum.find(fn {index, value} ->
      legend_label(value) != Question.Score.label(Enum.at(question_levels, index))
    end)
    |> case do
      nil ->
        :ok

      {index, value} ->
        {:error,
         Error.unexpected(
           "score answer for #{inspect(wire_id)} has a legend that disagrees with the " <>
             "question: level #{index} was sent as " <>
             "#{inspect(Question.Score.label(Enum.at(question_levels, index)))} but the legend " <>
             "calls it #{inspect(legend_label(value))}",
           raw_legend
         )}
    end
  end

  defp legend_label(value) when is_binary(value), do: value
  defp legend_label(%{"label" => label}) when is_binary(label), do: label
  defp legend_label(value), do: Question.Score.label(value)

  # String keys ("0", "1", ...) parsed to their level index. Never
  # `String.to_atom/1`; anything that isn't a clean non-negative integer fails,
  # and so does an index the question has no level for.
  defp decode_integer_keyed(map, wire_id, count) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Integer.parse(to_string_key(key)) do
        {index, ""} when index >= 0 and index < count ->
          {:cont, {:ok, Map.put(acc, index, value)}}

        {index, ""} when index >= 0 ->
          {:halt,
           {:error,
            Error.unexpected(
              "level key #{index} for #{inspect(wire_id)} is outside the question's #{count} " <>
                "levels (0..#{count - 1})",
              map
            )}}

        _invalid ->
          {:halt, {:error, integer_key_error(wire_id, key, map)}}
      end
    end)
  end

  defp decode_integer_keyed(other, wire_id, _count) do
    {:error, integer_key_error(wire_id, other, other)}
  end

  defp to_string_key(key) when is_binary(key), do: key
  defp to_string_key(key), do: inspect(key)

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
