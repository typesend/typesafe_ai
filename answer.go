package typesafe

import (
	"fmt"
	"strconv"
)

// Answer is one of *NoulAnswer, *ChoiceAnswer, or *ScoreAnswer. Use a type
// switch, or the typed accessors on Result.
type Answer interface {
	// ID is the question id the answer belongs to.
	ID() string
	// Confidence is what Gate uses: the wire confidence for Choice and Score,
	// and max(noul, 1-noul) for Noul, a local convention since the API
	// returns no confidence for Noul answers.
	Confidence() float64
}

// Gate classifies an answer by its Confidence against two thresholds:
// >= act is GateAct, >= review is GateReview, otherwise GateEscalate.
// It panics if act < review, since that makes the review band unreachable.
func Gate(a Answer, act, review float64) GateVerdict {
	if act < review {
		panic(fmt.Sprintf("typesafe.Gate: act (%v) must be >= review (%v)", act, review))
	}
	c := a.Confidence()
	switch {
	case c >= act:
		return GateAct
	case c >= review:
		return GateReview
	}
	return GateEscalate
}

// GateVerdict is the result of Gate.
type GateVerdict string

const (
	// GateAct means confidence reached the act threshold: safe to act on.
	GateAct GateVerdict = "act"
	// GateReview means confidence reached the review threshold but not act:
	// act after a confirmation step.
	GateReview GateVerdict = "review"
	// GateEscalate means confidence fell below both thresholds: hand off.
	GateEscalate GateVerdict = "escalate"
)

// NoulAnswer is the probability that the answer is yes.
type NoulAnswer struct {
	id   string
	Noul float64
}

// ID is the question id this answer belongs to.
func (a *NoulAnswer) ID() string { return a.id }

// Confidence is max(Noul, 1-Noul): how far the probability sits from 0.5.
func (a *NoulAnswer) Confidence() float64 {
	if a.Noul >= 0.5 {
		return a.Noul
	}
	return 1 - a.Noul
}

// Yes reports whether Noul is at least threshold (use 0.5 for a plain yes).
func (a *NoulAnswer) Yes(threshold float64) bool { return a.Noul >= threshold }

// ChoiceAnswer is the winning option with the full distribution.
type ChoiceAnswer struct {
	id            string
	Choice        string
	Probabilities map[string]float64
	confidence    float64
}

// ID is the question id this answer belongs to.
func (a *ChoiceAnswer) ID() string { return a.id }

// Confidence is the API's confidence in Choice, from 0 to 1.
func (a *ChoiceAnswer) Confidence() float64 { return a.confidence }

// ScoreAnswer is a position on the scale with the full distribution.
type ScoreAnswer struct {
	id string
	// Score is the probability-weighted position, 0 to len(Levels)-1; it can
	// land between levels.
	Score float64
	// Level is the index of the most probable level (lowest index on ties).
	Level int
	// Label is the winning level's label, always a string.
	Label string
	// Description is the winning level exactly as written in the question.
	Description Description
	// Levels pairs every question level's label with its probability, in order.
	Levels []LevelProbability
	// Probabilities is keyed by level index.
	Probabilities map[int]float64
	// Legend is the API's own copy of the levels, keyed by index.
	Legend     map[int]any
	confidence float64
}

// LevelProbability is one entry of ScoreAnswer.Levels.
type LevelProbability struct {
	Label       string
	Probability float64
}

// ID is the question id this answer belongs to.
func (a *ScoreAnswer) ID() string { return a.id }

// Confidence is the API's confidence in the score, from 0 to 1.
func (a *ScoreAnswer) Confidence() float64 { return a.confidence }

// Normalized is Score divided by the top level index, so scales with
// different numbers of levels can be weighted against each other. It
// assumes Score lies within 0..top as the API guarantees and does not clamp.
func (a *ScoreAnswer) Normalized() float64 {
	top := len(a.Levels) - 1
	if top <= 0 {
		return 0
	}
	return a.Score / float64(top)
}

// -- decoding ----------------------------------------------------------------

func decodeAnswer(id string, raw any, q Question) (Answer, error) {
	m, ok := raw.(map[string]any)
	if !ok {
		return nil, unexpectedError(raw, "answer %q must be a JSON object", id)
	}
	typ, _ := m["type"].(string)
	if typ != q.wireType() {
		return nil, unexpectedError(m, "answer %q does not match its question type: expected %q, got %q", id, q.wireType(), typ)
	}
	switch q := q.(type) {
	case *NoulQuestion:
		v, ok := number(m["noul"])
		if !ok {
			return nil, unexpectedError(m, "invalid noul answer for %q", id)
		}
		return &NoulAnswer{id: id, Noul: v}, nil
	case *ChoiceQuestion:
		choice, ok := m["choice"].(string)
		conf, okc := number(m["confidence"])
		probs, okp := m["probabilities"].(map[string]any)
		if !ok || !okc || !okp {
			return nil, unexpectedError(m, "invalid choice answer for %q", id)
		}
		p := make(map[string]float64, len(probs))
		for k, v := range probs {
			f, ok := number(v)
			if !ok {
				return nil, unexpectedError(m, "invalid choice probabilities for %q", id)
			}
			p[k] = f
		}
		return &ChoiceAnswer{id: id, Choice: choice, Probabilities: p, confidence: conf}, nil
	case *ScoreQuestion:
		return decodeScore(id, m, q)
	}
	return nil, unexpectedError(m, "unknown question type for %q", id)
}

func decodeScore(id string, m map[string]any, q *ScoreQuestion) (Answer, error) {
	score, oks := number(m["score"])
	conf, okc := number(m["confidence"])
	rawProbs, okp := m["probabilities"].(map[string]any)
	if !oks || !okc || !okp {
		return nil, unexpectedError(m, "invalid score answer for %q", id)
	}
	probs := make(map[int]float64, len(rawProbs))
	for k, v := range rawProbs {
		idx, err := levelIndex(k)
		if err != nil {
			return nil, unexpectedError(m, "invalid level key %q for %q", k, id)
		}
		f, ok := number(v)
		if !ok {
			return nil, unexpectedError(m, "invalid score probabilities for %q", id)
		}
		probs[idx] = f
	}
	legend := map[int]any{}
	if rawLegend, ok := m["legend"].(map[string]any); ok {
		for k, v := range rawLegend {
			idx, err := levelIndex(k)
			if err != nil {
				return nil, unexpectedError(m, "invalid legend key %q for %q", k, id)
			}
			legend[idx] = v
		}
	}
	levels := make([]LevelProbability, len(q.Levels))
	best := 0
	for i, l := range q.Levels {
		levels[i] = LevelProbability{Label: l.label(), Probability: probs[i]}
		if probs[i] > probs[best] {
			best = i
		}
	}
	return &ScoreAnswer{
		id:            id,
		Score:         score,
		Level:         best,
		Label:         q.Levels[best].label(),
		Description:   q.Levels[best].Description,
		Levels:        levels,
		Probabilities: probs,
		Legend:        legend,
		confidence:    conf,
	}, nil
}

func levelIndex(k string) (int, error) {
	i, err := strconv.Atoi(k)
	if err != nil || i < 0 {
		return 0, fmt.Errorf("bad level index %q", k)
	}
	return i, nil
}

func number(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	}
	return 0, false
}
