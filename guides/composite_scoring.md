# Composite scoring

Ranking items on several criteria at once is easier when each criterion is its own Score
question and the weights live in your code. That is the official
[composite-scoring pattern](https://docs.typesafe.ai/patterns/composite-scoring): break the
judgment into atomic dimensions, score each independently, and combine them with weights you
can see and change.

## The dimensions

Resume screening for engineering roles, four dimensions, five levels each:

```elixir
defmodule MyApp.Screening do
  @questions [
    python_depth:
      TypeSafe.score(
        "How much depth of python experience does this candidate have, based on the supplied resume?",
        [
          "No Python experience mentioned",
          "Mentioned but no detail",
          "Used in projects, some specifics",
          "Primary language, multiple projects",
          "Deep expertise: architecture, performance, libraries"
        ]
      ),
    team_leadership:
      TypeSafe.score(
        "How much experience does this candidate have managing or leading engineering teams?",
        [
          "No management experience mentioned",
          "Informal mentorship or tech lead role",
          "Led a small team or project",
          "Managed a team with direct reports",
          "Managed multiple teams or an engineering org"
        ]
      ),
    system_design:
      TypeSafe.score(
        "How much experience does this candidate have designing large-scale or distributed systems?",
        [
          "No architecture work mentioned",
          "Contributed to design discussions",
          "Designed components of a larger system",
          "Owned architecture of a significant system",
          "Designed systems at scale across multiple domains"
        ]
      ),
    generalist:
      TypeSafe.score(
        "How much evidence is there that this candidate picks up unfamiliar tools, roles, or domains outside their core specialty?",
        [
          "Only one domain or role mentioned",
          "Some variety but within a narrow field",
          "Worked across a few different areas or tech stacks",
          "Regularly moved between domains, wore many hats",
          "Track record of ramping up in unfamiliar areas and delivering"
        ]
      )
  ]

  def questions, do: @questions
end
```

## Combining with weights

`TypeSafe.Answer.Score.normalized/1` divides the score by the top level index, so every
dimension lands on 0 to 1 regardless of how many levels it has.

```elixir
defmodule MyApp.Screening do
  # ... @questions from above ...

  alias TypeSafe.Answer.Score

  @ic_weights %{python_depth: 0.40, team_leadership: 0.10, system_design: 0.40, generalist: 0.10}
  @em_weights %{python_depth: 0.15, team_leadership: 0.40, system_design: 0.20, generalist: 0.25}

  def rank(client, resumes, role) do
    weights = if role == :engineering_manager, do: @em_weights, else: @ic_weights

    client
    |> TypeSafe.evaluate_many(Enum.map(resumes, & &1.text), @questions, max_concurrency: 8)
    |> Enum.zip(resumes)
    |> Enum.flat_map(fn
      {{:ok, result}, resume} -> [{resume, composite(result.answers, weights)}]
      {{:error, _error}, _resume} -> []
    end)
    |> Enum.sort_by(fn {_resume, score} -> score end, :desc)
  end

  defp composite(answers, weights) do
    Enum.reduce(weights, 0.0, fn {dimension, weight}, acc ->
      acc + weight * Score.normalized(answers[dimension])
    end)
  end
end
```

The ranking is transparent: if the top candidates do not match your expectations, the
weights are right there to adjust, and the per-dimension scores in each `Result` explain
why a candidate landed where they did.

## Reading the distribution, not just the score

A Score answer also carries `levels`, the probability of each level in order, and
`confidence`. Two candidates with the same 2.0 score can look very different: one with all
probability on level 2, another split between levels 0 and 4. When that matters, weight by
confidence too, or drop low-confidence dimensions:

```elixir
defp composite(answers, weights) do
  Enum.reduce(weights, 0.0, fn {dimension, weight}, acc ->
    answer = answers[dimension]
    if answer.confidence < 0.4, do: acc, else: acc + weight * Score.normalized(answer)
  end)
end
```
