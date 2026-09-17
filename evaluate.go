package typesafe

import (
	"context"
	"fmt"
	"net/http"
	"runtime/debug"
	"sync"
	"time"
)

// SystemOnePath is the evaluation endpoint.
const SystemOnePath = "/v1/systemone"

// State is what the questions are about: a string, or JSON-shaped data
// (map[string]any, []any, or any struct that encodes to an object or array).
type State = any

// Evaluate sends state and questions and returns typed answers. Questions
// are validated locally first; a malformed question returns an *Error of
// type ErrValidation without a request. Errors are always *Error.
func (c *Client) Evaluate(ctx context.Context, state State, qs Questions, opts ...CallOptions) (*Result, error) {
	prepared, err := Prepare(qs)
	if err != nil {
		return nil, err
	}
	return c.EvaluatePrepared(ctx, state, prepared, opts...)
}

// Prepared is a validated, encoded question set that can be reused across
// many states.
type Prepared struct {
	questions Questions
	encoded   map[string]any
}

// Prepare validates and encodes a question set once.
func Prepare(qs Questions) (*Prepared, error) {
	if err := qs.Validate(); err != nil {
		return nil, err
	}
	return &Prepared{questions: qs, encoded: qs.encode()}, nil
}

// Count is the number of questions.
func (p *Prepared) Count() int { return len(p.questions) }

// EvaluatePrepared evaluates state against a prepared question set.
func (c *Client) EvaluatePrepared(ctx context.Context, state State, p *Prepared, opts ...CallOptions) (*Result, error) {
	if err := validateState(state); err != nil {
		return nil, err
	}
	var opt CallOptions
	if len(opts) > 0 {
		opt = opts[0]
	}
	model := c.model
	if opt.Model != "" {
		model = opt.Model
	}
	body := map[string]any{"state": state, "model": model, "questions": p.encoded}
	resp, err := c.Do(ctx, http.MethodPost, SystemOnePath, body, opt)
	if err != nil {
		return nil, err
	}
	res, err := decodeResult(resp.Body, p.questions)
	if err != nil {
		if e, ok := err.(*Error); ok {
			e.Status = resp.Status
			e.RequestID = resp.RequestID
		}
		return nil, err
	}
	res.RequestID = resp.RequestID
	return res, nil
}

func validateState(state State) error {
	switch state.(type) {
	case nil:
		return validationError("state is required")
	case string, map[string]any, []any, []string, map[string]string:
		return nil
	case bool, int, int64, float64:
		return validationError("state must be a string, map, or list, got %T", state)
	}
	return nil // structs and slices are encoded by json.Marshal
}

// Outcome is one entry of EvaluateMany's results: exactly one of Result
// or Err is set.
type Outcome struct {
	Result *Result
	Err    *Error
}

// ManyOptions configure EvaluateMany. The zero value is usable.
type ManyOptions struct {
	// MaxConcurrency caps in-flight requests. Default 8, a guess: TypeSafe
	// has not published rate limits.
	MaxConcurrency int
	// Timeout bounds one state's whole call, retries included. Default:
	// WorstCaseDuration of the effective policy (budget plus one attempt),
	// so a legitimate retry is never cut short.
	Timeout time.Duration
	// Call options applied to every request.
	Call CallOptions
}

// EvaluateMany evaluates each state against one question set concurrently
// and returns one Outcome per state, in input order. A failed state never
// hides the others: errors, timeouts, and even panics in hooks or encoding
// are isolated to their own Outcome. The question set is validated and
// encoded once; an invalid set returns an error and no requests are sent.
// Cancel ctx to stop early; in-flight calls end with ErrConnection or
// ErrTimeout outcomes.
func (c *Client) EvaluateMany(ctx context.Context, states []State, qs Questions, opts ...ManyOptions) ([]Outcome, error) {
	var opt ManyOptions
	if len(opts) > 0 {
		opt = opts[0]
	}
	if opt.MaxConcurrency <= 0 {
		opt.MaxConcurrency = 8
	}
	if opt.Timeout == 0 {
		timeout, policy := c.timeout, c.retry
		if opt.Call.Timeout > 0 {
			timeout = opt.Call.Timeout
		}
		if opt.Call.Retry != nil {
			policy = *opt.Call.Retry
		}
		opt.Timeout = WorstCaseDuration(timeout, policy)
	}
	prepared, err := Prepare(qs)
	if err != nil {
		return nil, err
	}
	outcomes := make([]Outcome, len(states))
	sem := make(chan struct{}, opt.MaxConcurrency)
	var wg sync.WaitGroup
	for i, state := range states {
		wg.Add(1)
		go func(i int, state State) {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
			case <-ctx.Done():
				outcomes[i] = Outcome{Err: &Error{Type: ErrConnection, Message: "cancelled before start: " + ctx.Err().Error(), Err: ctx.Err()}}
				return
			}
			defer func() { <-sem }()
			outcomes[i] = c.evaluateOne(ctx, state, prepared, opt)
		}(i, state)
	}
	wg.Wait()
	return outcomes, nil
}

// evaluateOne runs a single state under its own timeout and converts a
// panic into an Outcome error, so one bad state cannot take down the batch.
func (c *Client) evaluateOne(ctx context.Context, state State, prepared *Prepared, opt ManyOptions) (out Outcome) {
	defer func() {
		if r := recover(); r != nil {
			out = Outcome{Err: &Error{Type: ErrUnexpected,
				Message: fmt.Sprintf("panic evaluating state: %v\n%s", r, debug.Stack())}}
		}
	}()
	sctx, cancel := context.WithTimeout(ctx, opt.Timeout)
	defer cancel()
	res, err := c.EvaluatePrepared(sctx, state, prepared, opt.Call)
	if err != nil {
		e, _ := err.(*Error)
		if e == nil {
			e = &Error{Type: ErrUnexpected, Message: err.Error(), Err: err}
		}
		if sctx.Err() != nil && ctx.Err() == nil {
			e.Type = ErrTimeout
			e.Message = "state exceeded the per-state timeout of " + opt.Timeout.String()
		}
		return Outcome{Err: e}
	}
	return Outcome{Result: res}
}

// FirstError returns the first error outcome in input order, or nil.
func FirstError(outcomes []Outcome) *Error {
	for _, o := range outcomes {
		if o.Err != nil {
			return o.Err
		}
	}
	return nil
}

// WorstCaseDuration is how long one call can take under a policy: the
// budget plus one attempt timeout, since the budget gates starting a retry
// rather than an in-flight attempt.
func WorstCaseDuration(timeout time.Duration, p RetryPolicy) time.Duration {
	if p.Budget == 0 {
		return time.Duration(p.MaxRetries+1)*timeout + time.Duration(p.MaxRetries)*p.BackoffMax
	}
	return p.Budget + timeout
}
