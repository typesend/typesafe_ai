package typesafe

import (
	"context"
	"fmt"
	"iter"
	"net/http"
	"reflect"
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
	if state == nil {
		return validationError("state is required")
	}
	switch reflect.TypeOf(state).Kind() {
	case reflect.String, reflect.Map, reflect.Slice, reflect.Array, reflect.Struct:
		return nil
	case reflect.Pointer:
		if reflect.ValueOf(state).IsNil() {
			return validationError("state is required")
		}
		return validateState(reflect.ValueOf(state).Elem().Interface())
	}
	return validationError("state must be a string, map, or list, got %T", state)
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
// A fixed pool of MaxConcurrency workers processes the states, so memory is
// bounded by the input slice, not by goroutines. Cancelling ctx stops
// unstarted states immediately and ends in-flight calls, including retry
// sleeps, with ErrConnection or ErrTimeout outcomes; the call returns once
// every worker has unwound. For inputs too large to hold in memory, or to
// consume results as they complete, use EvaluateStream.
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
	for i, o := range c.evaluateStream(ctx, sliceSeq(states), prepared, opt) {
		outcomes[i] = o
	}
	return outcomes, nil
}

// EvaluateStream evaluates states from an iterator with bounded concurrency
// and yields (index, Outcome) pairs as each state finishes, in completion
// order. Use it when the input is too large to hold in memory or when you
// want to consume results before the slowest state completes. At most
// MaxConcurrency states are in flight or pulled from the iterator ahead of
// consumption, so a lazy source (a database cursor, a file) is read on
// demand. Stopping the range loop early cancels the remaining work.
//
// The question set is validated once; a validation error is yielded as the
// single outcome for index -1.
func (c *Client) EvaluateStream(ctx context.Context, states iter.Seq[State], qs Questions, opts ...ManyOptions) iter.Seq2[int, Outcome] {
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
		return func(yield func(int, Outcome) bool) { yield(-1, Outcome{Err: err.(*Error)}) }
	}
	return c.evaluateStream(ctx, states, prepared, opt)
}

type indexed struct {
	i       int
	outcome Outcome
}

// evaluateStream is the engine behind EvaluateMany and EvaluateStream: a
// fixed pool of MaxConcurrency workers pulling from the iterator, so
// admission is bounded as well as concurrency.
func (c *Client) evaluateStream(ctx context.Context, states iter.Seq[State], prepared *Prepared, opt ManyOptions) iter.Seq2[int, Outcome] {
	return func(yield func(int, Outcome) bool) {
		ctx, cancel := context.WithCancel(ctx)
		defer cancel()
		jobs := make(chan indexedState)
		results := make(chan indexed)
		var wg sync.WaitGroup
		for w := 0; w < opt.MaxConcurrency; w++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for job := range jobs {
					out := c.evaluateOne(ctx, job.state, prepared, opt)
					select {
					case results <- indexed{job.i, out}:
					case <-ctx.Done():
						return
					}
				}
			}()
		}
		go func() {
			defer close(jobs)
			i := 0
			for state := range states {
				select {
				case jobs <- indexedState{i, state}:
				case <-ctx.Done():
					return
				}
				i++
			}
		}()
		go func() {
			wg.Wait()
			close(results)
		}()
		for r := range results {
			if !yield(r.i, r.outcome) {
				cancel()
				for range results { // drain so workers can exit
				}
				return
			}
		}
	}
}

type indexedState struct {
	i     int
	state State
}

func sliceSeq(states []State) iter.Seq[State] {
	return func(yield func(State) bool) {
		for _, s := range states {
			if !yield(s) {
				return
			}
		}
	}
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
