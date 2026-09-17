# System One concepts

What TypeSafe's System One models are, starting with Jev, why they answer in
probabilities instead of prose, and when to reach for something else instead. Full reference:
[docs.typesafe.ai](https://docs.typesafe.ai).

## Why probabilities, not prose

System One models are small, fast models built for calibrated decisions about a piece
of content, not for generating text. Jev is TypeSafe's first System One model; this
client defaults to the `jev-latest` alias and the API reports the resolved version in
every result. Instead of asking a general LLM to write a reply
and then parsing it back into a decision, you ask System One a typed question and it
answers with a probability distribution over a fixed set of outcomes. There is no
completion to parse, no prompt-injection surface in the output, and no risk of the
model answering in the wrong shape — the shape is the API contract.

That trade only pays off for snap judgments: "is this urgent", "which team owns this",
"how angry is this customer". It is the wrong tool for anything that needs the model to
produce new text, reason at length, or use tools.

## The three question types

Every question is about a single piece of `state` (text, or a JSON-shaped map or
list) and comes back with a probability, not a label alone.

* **Noul** — a yes/no judgment on a question ("Does this convey urgency?") or a
  statement to evaluate ("This message contains unsolicited advertising."). The answer
  is the probability of yes (or of the statement being true), a single number from 0
  to 1. The API sends no separate confidence for a Noul answer — a confident "no" and
  a confident "yes" are equally confident — so this library derives one,
  `max(noul, 1 - noul)`, and puts it on the answer's `confidence` field as well as
  returning it from `TypeSafeAPI.Answer.confidence/1`. It never drops below 0.5, which
  is why `TypeSafeAPI.Answer.gate/2` wants a `review:` threshold above 0.5 for a Noul.

* **Choice** — pick one option from a set you define, 2 to 255 of them in this
  library. The answer is the chosen option, a probability per option (all options sum
  to 1), and a confidence: how peaked that distribution is on the winner. Give a Choice
  an `other` option whenever the set might not cover every input — without one, the
  model is forced into the closest listed option even when none of them really fit.

* **Score** — a position on an ordered scale you write as a list of levels from low to
  high, 2 to 10 of them in this library. The answer is not just the winning level: it
  is a fractional score between levels (for example `1.6` between level 1 and level 2),
  the probability of each level, and a confidence. The fractional score is the point of
  Score over Choice for anything you plan to threshold or average — "how angry is
  this" wants a number you can compare across tickets, not just a bucket.

`instructions` is optional on all three types. A Choice or Score still needs its
`criteria` (the options or levels); a Noul needs neither.

## Reading confidence

`confidence` says how peaked the model's probability distribution is on its answer,
from 0 (the model is torn between options) to 1 (one option or level dominates). It is
not the same as "how likely is this the right answer" in an absolute sense — it is a
property of the distribution the model returned for *this* piece of state, not a
calibration guarantee. Use it as a gate: route to a human when confidence is low
regardless of which option won. `TypeSafeAPI.Answer.gate/2` implements exactly that
pattern (`:act` above a high threshold, `:review` above a lower one, `:escalate`
otherwise), and `TypeSafeAPI.Answer.confidence/1` is what `gate/2` reads for any answer
type, Noul included.

## When to reach for something else

System One is for classification and rating over content you already have, not for
producing content. Reach for a different tool when:

* **You need the model to write something** — a reply, a summary, a document. That is
  what a general LLM (Claude, GPT, or similar) is for; System One has no free-text
  output at all.
* **The decision needs multi-step reasoning or tool use** — looking things up,
  chaining several judgments together with branching logic beyond "ask everything up
  front and let code decide," or taking an action. System One answers one flat batch
  of independent questions per call; it is not an agent loop.
  ([Speculative fan-out](speculative_fan_out.md) covers asking everything a decision
  tree might need in a single request instead.)
* **A fixed set of System One questions can't capture your domain well enough, and you
  ask the same shape of question constantly** — that is a signal to look at
  fine-tuning a model for your specific criteria rather than continuing to hand-tune
  instructions and criteria on a general-purpose model. TypeSafe's docs cover
  fine-tuning options; this library only speaks to the models the API already exposes
  under `GET /v1/models`.
* **You need free-form extraction** (pull every date mentioned, summarize into
  bullets) rather than a judgment against options you define upfront. System One's
  answer shapes are fixed by the question type; there is no way to get an open-ended
  structured extraction out of it.

See [docs.typesafe.ai/concepts/system-one](https://docs.typesafe.ai/concepts/system-one)
for the canonical description of the models and their guarantees.
