package typesafe

// Usage is the token count for one call. A count is -1 when the API did
// not report it.
type Usage struct {
	InputTokens  int
	OutputTokens int
}

// Result is a fully decoded evaluation response.
type Result struct {
	// Model is the model that answered, for example "jev-1.13.0".
	Model string
	// Answers is keyed by the ids you chose. Use the typed accessors or a
	// type switch.
	Answers map[string]Answer
	Usage   Usage
	// RequestID is the x-typesafe-request-id header, for support requests.
	RequestID string
	// Raw is the decoded response body, including anything this package
	// does not model.
	Raw map[string]any
}

// Noul returns the Noul answer for id, or nil if absent or another type.
func (r *Result) Noul(id string) *NoulAnswer {
	a, _ := r.Answers[id].(*NoulAnswer)
	return a
}

// Choice returns the Choice answer for id, or nil if absent or another type.
func (r *Result) Choice(id string) *ChoiceAnswer {
	a, _ := r.Answers[id].(*ChoiceAnswer)
	return a
}

// Score returns the Score answer for id, or nil if absent or another type.
func (r *Result) Score(id string) *ScoreAnswer {
	a, _ := r.Answers[id].(*ScoreAnswer)
	return a
}

func decodeResult(body map[string]any, qs Questions) (*Result, error) {
	model, ok := body["model"].(string)
	if !ok {
		return nil, unexpectedError(body, `missing or invalid "model"`)
	}
	rawAnswers, ok := body["answers"].(map[string]any)
	if !ok {
		return nil, unexpectedError(body, `missing or invalid "answers"`)
	}
	rawUsage, ok := body["usage"].(map[string]any)
	if !ok {
		return nil, unexpectedError(body, `missing or invalid "usage"`)
	}
	answers := make(map[string]Answer, len(qs))
	for id, q := range qs {
		raw, ok := rawAnswers[id]
		if !ok {
			return nil, unexpectedError(rawAnswers, "missing answer for %q", id)
		}
		a, err := decodeAnswer(id, raw, q)
		if err != nil {
			return nil, err
		}
		answers[id] = a
	}
	return &Result{
		Model:   model,
		Answers: answers,
		Usage:   Usage{InputTokens: intField(rawUsage, "input_tokens"), OutputTokens: intField(rawUsage, "output_tokens")},
		Raw:     body,
	}, nil
}
