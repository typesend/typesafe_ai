defmodule TypeSafeAPI.Result do
  @moduledoc """
  A fully decoded response: every answer keyed by the caller's own question
  ids, plus usage and the raw decoded body for anything this layer doesn't
  expose yet.

  Decoding is strict about the envelope (`model` must be present and a string,
  every question must have an answer, every answer must agree with its
  question) but permissive in two places: an answer the caller never asked for
  is dropped from `answers` and stays reachable through `raw`, and a missing or
  malformed `usage` decodes to a `TypeSafeAPI.Usage` with `nil` counts rather
  than failing a complete set of answers. The spec marks `usage` required with
  both token counts required, so the tolerance is defensive, not permission.

  `retry_count` is how many retries the call burned before this response (0 when
  the first attempt succeeded). `request_id` is the `x-typesafe-request-id` response header, the value
  TypeSafe support asks for. `TypeSafeAPI.Error` carries the same field for
  failed calls, including for a body that failed to decode here.

  `raw` holds the whole decoded body, so a result carries a second copy of
  everything `answers` already holds. `inspect/1` elides it: read
  `result.raw` directly when you want it.
  """

  alias TypeSafeAPI.{Answer, Error, Keys, Question, Usage}

  @type t :: %__MODULE__{
          model: String.t(),
          answers: %{Keys.key() => Answer.t()},
          usage: Usage.t(),
          request_id: String.t() | nil,
          retry_count: non_neg_integer(),
          raw: map()
        }

  @enforce_keys [:model, :answers, :usage, :raw]
  defstruct [:model, :answers, :usage, :raw, request_id: nil, retry_count: 0]

  @doc """
  Decodes a response body against the questions that were sent.

  `questions` is the normalized `[{id, question}]` list (see
  `TypeSafeAPI.Question.normalize/1`) and `keys` is the `TypeSafeAPI.Keys` built
  from it, so answers come back keyed and valued under the caller's own ids.

  `request_id` is the `x-typesafe-request-id` header of the response being
  decoded. It lands on the `TypeSafeAPI.Result` on success and on the
  `TypeSafeAPI.Error` on failure, so a decode mismatch — the one failure that
  needs a support ticket — can be quoted. `decode/3` passes `nil`.
  """
  @spec decode(map(), [{Keys.key(), Question.t()}], Keys.t(), String.t() | nil) ::
          {:ok, t()} | {:error, Error.t()}
  def decode(body, questions, keys, request_id \\ nil)

  def decode(body, questions, keys, request_id) when is_map(body) and is_list(questions) do
    with {:ok, model} <- fetch_model(body),
         {:ok, raw_answers} <- fetch_answers(body),
         {:ok, answers} <- decode_answers(raw_answers, questions, keys) do
      {:ok,
       %__MODULE__{
         model: model,
         answers: answers,
         usage: Usage.decode(Map.get(body, "usage")),
         request_id: request_id,
         raw: body
       }}
    else
      {:error, error} -> {:error, %{error | request_id: request_id}}
    end
  end

  defp fetch_model(%{"model" => model}) when is_binary(model), do: {:ok, model}
  defp fetch_model(body), do: {:error, Error.unexpected("missing or invalid \"model\"", body)}

  defp fetch_answers(%{"answers" => answers}) when is_map(answers), do: {:ok, answers}
  defp fetch_answers(body), do: {:error, Error.unexpected("missing or invalid \"answers\"", body)}

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

  defimpl Inspect do
    import Inspect.Algebra

    # `raw` is a second copy of everything above it, so printing a result would
    # otherwise print the whole response twice. Read `result.raw` for it.
    def inspect(result, opts) do
      fields = [
        model: to_doc(result.model, opts),
        answers: to_doc(result.answers, opts),
        usage: to_doc(result.usage, opts),
        request_id: to_doc(result.request_id, opts),
        raw: "#elided"
      ]

      container_doc("#TypeSafeAPI.Result<", fields, ">", opts, fn {key, doc}, _opts ->
        concat([Atom.to_string(key), ": ", doc])
      end)
    end
  end
end
