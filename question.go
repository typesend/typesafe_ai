package typesafe

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// Description is anything the API accepts where text goes: a string, or
// JSON-shaped structure (map[string]any, []any, or any value that encodes
// to a JSON object or array).
type Description = any

// Question is one of Noul, Choice, or Score. Build them with the
// constructors; the interface is closed.
type Question interface {
	wireType() string
	validate() error
	encode() any
}

// Questions maps caller-chosen ids to questions. Ids are not sent to the
// model; answers come back under the same ids.
type Questions map[string]Question

// -- Noul --------------------------------------------------------------------

// NoulQuestion asks yes or no. The answer is the probability of yes.
type NoulQuestion struct {
	Instructions Description
	// True and False describe what each answer means. Optional.
	True, False Description
}

// Noul builds a yes/no question. Optional NoulOptions describe the criteria.
func Noul(instructions Description, opts ...NoulOption) *NoulQuestion {
	q := &NoulQuestion{Instructions: instructions}
	for _, o := range opts {
		o(q)
	}
	return q
}

// NoulOption configures a NoulQuestion.
type NoulOption func(*NoulQuestion)

// WhenTrue describes what a yes (value near 1) means.
func WhenTrue(d Description) NoulOption { return func(q *NoulQuestion) { q.True = d } }

// WhenFalse describes what a no (value near 0) means.
func WhenFalse(d Description) NoulOption { return func(q *NoulQuestion) { q.False = d } }

func (q *NoulQuestion) wireType() string { return "noul" }

func (q *NoulQuestion) validate() error {
	if err := validateDescription(q.Instructions, "instructions", false); err != nil {
		return err
	}
	if err := validateDescription(q.True, "criteria.true", true); err != nil {
		return err
	}
	return validateDescription(q.False, "criteria.false", true)
}

func (q *NoulQuestion) encode() any {
	m := map[string]any{"type": "noul", "instructions": q.Instructions}
	if q.True != nil || q.False != nil {
		criteria := map[string]any{}
		if q.True != nil {
			criteria["true"] = q.True
		}
		if q.False != nil {
			criteria["false"] = q.False
		}
		m["criteria"] = criteria
	}
	return m
}

// -- Choice ------------------------------------------------------------------

// ChoiceOption is one option of a Choice: a key and an optional description.
type ChoiceOption struct {
	Key         string
	Description Description // nil when the key speaks for itself
}

// Opt builds a ChoiceOption. Pass nil as the description when the key
// speaks for itself.
func Opt(key string, description Description) ChoiceOption {
	return ChoiceOption{Key: key, Description: description}
}

// ChoiceQuestion picks one option from an ordered set. The order is what
// the model sees and is preserved on the wire. The API allows 2 to 255
// options; give it the full list and add an "other" option when the list
// might not cover every input.
type ChoiceQuestion struct {
	Instructions Description
	Options      []ChoiceOption
}

// Choice builds a Choice question from ordered options.
func Choice(instructions Description, options ...ChoiceOption) *ChoiceQuestion {
	return &ChoiceQuestion{Instructions: instructions, Options: options}
}

// ChoiceKeys builds a Choice whose options have no descriptions.
func ChoiceKeys(instructions Description, keys ...string) *ChoiceQuestion {
	opts := make([]ChoiceOption, len(keys))
	for i, k := range keys {
		opts[i] = ChoiceOption{Key: k}
	}
	return Choice(instructions, opts...)
}

const (
	minChoiceOptions = 2
	maxChoiceOptions = 255
)

func (q *ChoiceQuestion) wireType() string { return "choice" }

func (q *ChoiceQuestion) validate() error {
	if err := validateDescription(q.Instructions, "instructions", false); err != nil {
		return err
	}
	n := len(q.Options)
	if n < minChoiceOptions {
		return validationError("Choice needs at least %d options, got %d", minChoiceOptions, n)
	}
	if n > maxChoiceOptions {
		return validationError("Choice allows at most %d options, got %d", maxChoiceOptions, n)
	}
	seen := make(map[string]bool, n)
	for _, o := range q.Options {
		if o.Key == "" {
			return validationError("Choice option keys must not be empty")
		}
		if seen[o.Key] {
			return validationError("Choice option %q is given more than once", o.Key)
		}
		seen[o.Key] = true
		if err := validateDescription(o.Description, "criteria."+o.Key, true); err != nil {
			return err
		}
	}
	return nil
}

func (q *ChoiceQuestion) encode() any {
	pairs := make([]orderedPair, len(q.Options))
	for i, o := range q.Options {
		pairs[i] = orderedPair{o.Key, o.Description}
	}
	return map[string]any{"type": "choice", "instructions": q.Instructions, "criteria": orderedObject(pairs)}
}

// -- Score -------------------------------------------------------------------

// ScoreLevel is one level of a Score scale. Label is a short name returned
// in the answer; Description is what the model sees. When Label is empty
// the description (a string) is its own label.
type ScoreLevel struct {
	Label       string
	Description Description
}

// Level builds a labelled level. It is sent as {"label": ..., "description": ...}.
func Level(label string, description Description) ScoreLevel {
	return ScoreLevel{Label: label, Description: description}
}

// ScoreQuestion rates the state along an ordered scale of 2 to 10 levels,
// low to high.
type ScoreQuestion struct {
	Instructions Description
	Levels       []ScoreLevel
}

// Score builds a Score question from plain level descriptions.
func Score(instructions Description, levels ...string) *ScoreQuestion {
	ls := make([]ScoreLevel, len(levels))
	for i, l := range levels {
		ls[i] = ScoreLevel{Description: l}
	}
	return &ScoreQuestion{Instructions: instructions, Levels: ls}
}

// ScoreLevels builds a Score question from structured or labelled levels.
func ScoreLevels(instructions Description, levels ...ScoreLevel) *ScoreQuestion {
	return &ScoreQuestion{Instructions: instructions, Levels: levels}
}

const (
	minScoreLevels = 2
	maxScoreLevels = 10
)

func (q *ScoreQuestion) wireType() string { return "score" }

func (q *ScoreQuestion) validate() error {
	if err := validateDescription(q.Instructions, "instructions", false); err != nil {
		return err
	}
	n := len(q.Levels)
	if n < minScoreLevels {
		return validationError("Score needs at least %d levels, got %d", minScoreLevels, n)
	}
	if n > maxScoreLevels {
		return validationError("Score allows at most %d levels, got %d", maxScoreLevels, n)
	}
	for i, l := range q.Levels {
		if err := validateDescription(l.Description, fmt.Sprintf("levels[%d]", i), false); err != nil {
			return err
		}
	}
	return nil
}

func (q *ScoreQuestion) encode() any {
	levels := make([]any, len(q.Levels))
	for i, l := range q.Levels {
		if l.Label != "" {
			levels[i] = map[string]any{"label": l.Label, "description": l.Description}
		} else {
			levels[i] = l.Description
		}
	}
	return map[string]any{"type": "score", "instructions": q.Instructions, "criteria": levels}
}

// label is the string label for a level: the Label, a string description,
// or a truncated rendering of a structured description.
func (l ScoreLevel) label() string {
	if l.Label != "" {
		return l.Label
	}
	if s, ok := l.Description.(string); ok {
		return s
	}
	b, err := json.Marshal(l.Description)
	if err != nil {
		return fmt.Sprintf("%v", l.Description)
	}
	const limit = 60
	if len(b) <= limit {
		return string(b)
	}
	return string(b[:limit-3]) + "..."
}

// -- shared ------------------------------------------------------------------

func validateDescription(v any, field string, allowNil bool) error {
	if v == nil {
		if allowNil {
			return nil
		}
		return validationError("%s is required", field)
	}
	switch v.(type) {
	case string, map[string]any, []any, []string, map[string]string:
		return nil
	}
	// Anything else must at least be JSON-encodable.
	if _, err := json.Marshal(v); err != nil {
		return validationError("%s is not JSON-encodable: %v", field, err)
	}
	return nil
}

// Validate checks every question locally, the same checks Evaluate runs
// before sending. Ids must be non-empty.
func (qs Questions) Validate() error {
	if len(qs) == 0 {
		return validationError("at least one question is required")
	}
	for id, q := range qs {
		if id == "" {
			return validationError("question ids must not be empty")
		}
		if q == nil {
			return validationError("question %q is nil", id)
		}
		if err := q.validate(); err != nil {
			e := err.(*Error)
			e.Message = fmt.Sprintf("question %q: %s", id, e.Message)
			return e
		}
	}
	return nil
}

func (qs Questions) encode() map[string]any {
	out := make(map[string]any, len(qs))
	for id, q := range qs {
		out[id] = q.encode()
	}
	return out
}

// orderedObject encodes as a JSON object in slice order. Go maps randomise
// key order, and a Choice with up to 255 options needs its order intact.
type orderedPair struct {
	key   string
	value any
}

type orderedObject []orderedPair

// MarshalJSON writes the pairs as a JSON object in slice order.
func (o orderedObject) MarshalJSON() ([]byte, error) {
	var buf bytes.Buffer
	buf.WriteByte('{')
	for i, p := range o {
		if i > 0 {
			buf.WriteByte(',')
		}
		k, err := json.Marshal(p.key)
		if err != nil {
			return nil, err
		}
		v, err := json.Marshal(p.value)
		if err != nil {
			return nil, err
		}
		buf.Write(k)
		buf.WriteByte(':')
		buf.Write(v)
	}
	buf.WriteByte('}')
	return buf.Bytes(), nil
}
