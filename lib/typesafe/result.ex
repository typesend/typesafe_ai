defmodule TypeSafe.Result do
  @moduledoc """
  A fully decoded response: every answer keyed by the caller's own question
  ids, plus usage and the raw decoded body for anything this layer doesn't
  expose yet.

  Decoding is strict about the envelope (`model` and `usage` must be present
  and well-formed, every question must have an answer) but permissive about
  the payload: an answer the caller never asked for is dropped from
  `answers` but stays reachable through `raw`.

  `request_id` is the `x-typesafe-request-id` response header, the value
  TypeSafe support asks for. `TypeSafe.Error` carries the same field for
  failed calls.
  """

  alias TypeSafe.{Answer, Error, Keys, Question, Usage}

  @type t :: %__MODULE__{
          model: String.t(),
          answers: %{Keys.key() => Answer.t()},
          usage: Usage.t(),
          request_id: String.t() | nil,
          raw: map()
        }

  @enforce_keys [:model, :answers, :usage, :raw]
  defstruct [:model, :answers, :usage, :raw, request_id: nil]

  @doc """
  Decodes a response body against the questions that were sent.

  `questions` is the normalized `[{id, question}]` list (see
  `TypeSafe.Question.normalize/1`) and `keys` is the `TypeSafe.Keys` built
  from it, so answers come back keyed and valued under the caller's own ids.
  """
  @spec decode(map(), [{Keys.key(), Question.t()}], Keys.t()) :: {:ok, t()} | {:error, Error.t()}
  def decode(body, questions, keys) when is_map(body) and is_list(questions) do
    with {:ok, model} <- fetch_model(body),
         {:ok, raw_answers} <- fetch_answers(body),
         {:ok, usage} <- fetch_usage(body),
         {:ok, answers} <- decode_answers(raw_answers, questions, keys) do
      {:ok, %__MODULE__{model: model, answers: answers, usage: usage, raw: body}}
    end
  end

  defp fetch_model(%{"model" => model}) when is_binary(model), do: {:ok, model}
  defp fetch_model(body), do: {:error, Error.unexpected("missing or invalid \"model\"", body)}

  defp fetch_answers(%{"answers" => answers}) when is_map(answers), do: {:ok, answers}
  defp fetch_answers(body), do: {:error, Error.unexpected("missing or invalid \"answers\"", body)}

  defp fetch_usage(%{"usage" => usage}) when is_map(usage), do: {:ok, Usage.decode(usage)}
  defp fetch_usage(body), do: {:error, Error.unexpected("missing or invalid \"usage\"", body)}

  defp decode_answers(raw_answers, questions, keys) do
    Enum.reduce_while(questions, {:ok, %{}}, fn {id, question}, {:ok, acc} ->
      wire_id = Keys.wire(id)

      with {:ok, raw_answer} <- fetch_raw_answer(raw_answers, wire_id, id),
           {:ok, answer} <- Answer.decode(raw_answer, wire_id, question, keys) do
        {:cont, {:ok, Map.put(acc, id, answer)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fetch_raw_answer(raw_answers, wire_id, id) do
    case Map.fetch(raw_answers, wire_id) do
      {:ok, raw_answer} -> {:ok, raw_answer}
      :error -> {:error, Error.unexpected("missing answer for #{inspect(id)}", raw_answers)}
    end
  end
end
