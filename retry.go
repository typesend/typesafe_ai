package typesafe

import (
	"math"
	"math/rand/v2"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// RetryPolicy mirrors the official TypeSafe SDKs' policy, including the
// total time budget per call that Go's usual per-attempt retries lack.
//
// The zero value is the default policy: every zero field means "use the
// default", and the boolean fields are phrased so that false is the safe
// setting. A partially filled literal such as RetryPolicy{MaxRetries: 5}
// therefore keeps the default statuses, backoff, and budget instead of
// silently disabling them. Use MaxRetries: -1 (or NoRetry) to disable
// retries and Budget: -1 to disable the budget.
//
// The budget gates the decision to start a retry, not an in-flight attempt:
// worst-case wall time is roughly Budget plus one attempt Timeout.
//
// With the defaults (10s attempt timeout, 500ms then 1s backoff, 30s
// budget):
//
//	three 529s      -> attempt, ~0.5s, attempt, ~1s, attempt, ErrOverloaded in about 1.5s
//	Retry-After: 20 -> attempt, 20s, attempt; a second Retry-After: 20 is
//	                   refused because 20s + 20s reaches the 30s budget
//	slow server     -> each attempt may take up to 10s, so a call can run
//	                   to about 40s before the last error is returned
//
// Official SDK option names map as follows (durations here are
// time.Duration rather than float seconds):
//
//	max_retries          MaxRetries
//	backoff_initial      BackoffInitial
//	backoff_max          BackoffMax
//	backoff_jitter       BackoffJitter
//	http_statuses        Statuses
//	respect_retry_after  !IgnoreRetryAfter
//	api_connection_error !NoRetryOnConnectionError
//	api_timeout_error    !NoRetryOnTimeout
//	timeout              Budget
//
// When both retry-after-ms and Retry-After are present, retry-after-ms
// wins. Retry-After may be seconds or an HTTP date. Unlike the JS SDK there
// is no cap on a server-supplied delay other than the budget.
type RetryPolicy struct {
	// MaxRetries after the initial attempt. 0 means the default of 2; a
	// negative value disables retries.
	MaxRetries int
	// BackoffInitial is the first delay, doubled each retry. 0 means 500ms.
	BackoffInitial time.Duration
	// BackoffMax caps the exponential delay. 0 means 5s.
	BackoffMax time.Duration
	// BackoffJitter is the fraction of each delay randomly subtracted, 0 to
	// 1. 0 means no jitter; the default policy uses 0.25.
	BackoffJitter float64
	// Statuses lists retryable HTTP statuses. nil means 408, 429, 500-599.
	Statuses []int
	// IgnoreRetryAfter disables honouring retry-after-ms and Retry-After.
	IgnoreRetryAfter bool
	// NoRetryOnConnectionError disables retrying when the server cannot be reached.
	NoRetryOnConnectionError bool
	// NoRetryOnTimeout disables retrying when one attempt times out.
	NoRetryOnTimeout bool
	// Budget is the total wall time per call including every attempt and
	// delay. 0 means 30s; a negative value disables the limit.
	Budget time.Duration

	// Sleep and Now replace the clock, for tests of code that depends on
	// retry timing. nil means time.Sleep and time.Now. A custom Sleep is
	// called with the delay and is not interrupted by context cancellation.
	Sleep func(time.Duration)
	Now   func() time.Time
}

// Default retry settings, shared with the official SDKs.
const (
	DefaultMaxRetries     = 2
	DefaultBackoffInitial = 500 * time.Millisecond
	DefaultBackoffMax     = 5 * time.Second
	DefaultBackoffJitter  = 0.25
	DefaultRetryBudget    = 30 * time.Second
)

// DefaultRetryStatuses returns the statuses retried by default: 408, 429,
// and 500 through 599.
func DefaultRetryStatuses() []int {
	statuses := []int{408, 429}
	for s := 500; s <= 599; s++ {
		statuses = append(statuses, s)
	}
	return statuses
}

// DefaultRetryPolicy returns the official defaults with every field filled
// in explicitly.
func DefaultRetryPolicy() RetryPolicy {
	return RetryPolicy{
		MaxRetries:     DefaultMaxRetries,
		BackoffInitial: DefaultBackoffInitial,
		BackoffMax:     DefaultBackoffMax,
		BackoffJitter:  DefaultBackoffJitter,
		Statuses:       DefaultRetryStatuses(),
		Budget:         DefaultRetryBudget,
	}
}

// NoRetry returns a policy that never retries.
func NoRetry() RetryPolicy {
	p := DefaultRetryPolicy()
	p.MaxRetries = -1
	return p
}

// normalized fills zero fields with the defaults and validates the rest.
func (p RetryPolicy) normalized() (RetryPolicy, error) {
	if p.BackoffJitter < 0 || p.BackoffJitter > 1 || math.IsNaN(p.BackoffJitter) {
		return p, validationError("retry: BackoffJitter must be between 0 and 1, got %v", p.BackoffJitter)
	}
	if p.BackoffInitial < 0 || p.BackoffMax < 0 {
		return p, validationError("retry: backoff durations must be non-negative")
	}
	if p.MaxRetries == 0 {
		p.MaxRetries = DefaultMaxRetries
	}
	if p.MaxRetries < 0 {
		p.MaxRetries = 0
	}
	if p.BackoffInitial == 0 {
		p.BackoffInitial = DefaultBackoffInitial
	}
	if p.BackoffMax == 0 {
		p.BackoffMax = DefaultBackoffMax
	}
	if p.Statuses == nil {
		p.Statuses = DefaultRetryStatuses()
	}
	if p.Budget == 0 {
		p.Budget = DefaultRetryBudget
	}
	if p.Budget < 0 {
		p.Budget = 0 // unlimited
	}
	return p, nil
}

func (p RetryPolicy) retryableStatus(status int) bool {
	for _, s := range p.Statuses {
		if s == status {
			return true
		}
	}
	return false
}

// Backoff returns the delay before retry number attempt (1-based): the
// initial delay doubled each retry, capped at BackoffMax, minus up to
// BackoffJitter of itself. It reads the policy as written; zero fields are
// not defaulted here.
func (p RetryPolicy) Backoff(attempt int) time.Duration {
	if p.BackoffInitial == 0 || p.BackoffMax == 0 || attempt < 1 {
		return 0
	}
	exp := float64(p.BackoffInitial) * math.Pow(2, float64(attempt-1))
	if exp > float64(p.BackoffMax) {
		exp = float64(p.BackoffMax)
	}
	jittered := exp * (1 - rand.Float64()*p.BackoffJitter)
	if jittered > exp {
		jittered = exp
	}
	return time.Duration(jittered)
}

// RetryAfter reads the server's requested wait from retry-after-ms
// (milliseconds) or Retry-After (seconds or an HTTP date). ok is false if
// neither header is usable.
func RetryAfter(h http.Header) (d time.Duration, ok bool) {
	if v := strings.TrimSpace(h.Get("retry-after-ms")); v != "" {
		if ms, err := strconv.ParseFloat(v, 64); err == nil && ms >= 0 && !math.IsInf(ms, 0) {
			return time.Duration(ms * float64(time.Millisecond)), true
		}
	}
	v := strings.TrimSpace(h.Get("Retry-After"))
	if v == "" {
		return 0, false
	}
	if secs, err := strconv.ParseFloat(v, 64); err == nil {
		if secs < 0 || math.IsInf(secs, 0) {
			return 0, false
		}
		return time.Duration(secs * float64(time.Second)), true
	}
	if t, err := http.ParseTime(v); err == nil {
		d := time.Until(t)
		if d < 0 {
			d = 0
		}
		return d, true
	}
	return 0, false
}

func (p RetryPolicy) delay(resp *http.Response, attempt int) time.Duration {
	if resp != nil && !p.IgnoreRetryAfter {
		if d, ok := RetryAfter(resp.Header); ok {
			return d
		}
	}
	return p.Backoff(attempt)
}

func (p RetryPolicy) nowFn() func() time.Time {
	if p.Now != nil {
		return p.Now
	}
	return time.Now
}
