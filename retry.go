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
// The budget gates the decision to start a retry, not an in-flight attempt:
// worst-case wall time is roughly Budget plus one attempt Timeout.
//
// When both retry-after-ms and Retry-After are present, retry-after-ms
// wins. Retry-After may be seconds or an HTTP date. Unlike the JS SDK there
// is no cap on a server-supplied delay other than the budget.
type RetryPolicy struct {
	// MaxRetries after the initial attempt; 0 disables retries. Default 2.
	MaxRetries int
	// BackoffInitial is the first delay, doubled each retry. Default 500ms.
	BackoffInitial time.Duration
	// BackoffMax caps the exponential delay. Default 5s. Zero disables backoff.
	BackoffMax time.Duration
	// BackoffJitter is the fraction of each delay randomly subtracted, 0 to 1.
	// Default 0.25.
	BackoffJitter float64
	// Statuses lists retryable HTTP statuses. Default 408, 429, 500-599.
	Statuses []int
	// RespectRetryAfter honours retry-after-ms and Retry-After. Default true.
	RespectRetryAfter bool
	// RetryConnectionErrors retries when the server cannot be reached. Default true.
	RetryConnectionErrors bool
	// RetryTimeoutErrors retries when one attempt times out. Default true.
	RetryTimeoutErrors bool
	// Budget is the total wall time per call including every attempt and
	// delay. Default 30s. Zero disables the limit.
	Budget time.Duration

	// sleep and now are injection points for tests.
	sleep func(time.Duration)
	now   func() time.Time
}

// DefaultRetryPolicy returns the official defaults.
func DefaultRetryPolicy() RetryPolicy {
	statuses := []int{408, 429}
	for s := 500; s <= 599; s++ {
		statuses = append(statuses, s)
	}
	return RetryPolicy{
		MaxRetries:            2,
		BackoffInitial:        500 * time.Millisecond,
		BackoffMax:            5 * time.Second,
		BackoffJitter:         0.25,
		Statuses:              statuses,
		RespectRetryAfter:     true,
		RetryConnectionErrors: true,
		RetryTimeoutErrors:    true,
		Budget:                30 * time.Second,
	}
}

// NoRetry returns a policy that never retries.
func NoRetry() RetryPolicy {
	p := DefaultRetryPolicy()
	p.MaxRetries = 0
	return p
}

func (p RetryPolicy) validate() error {
	if p.MaxRetries < 0 {
		return validationError("retry: MaxRetries must be non-negative, got %d", p.MaxRetries)
	}
	if p.BackoffInitial < 0 || p.BackoffMax < 0 || p.Budget < 0 {
		return validationError("retry: durations must be non-negative")
	}
	if p.BackoffJitter < 0 || p.BackoffJitter > 1 || math.IsNaN(p.BackoffJitter) {
		return validationError("retry: BackoffJitter must be between 0 and 1, got %v", p.BackoffJitter)
	}
	return nil
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
// BackoffJitter of itself.
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
	if resp != nil && p.RespectRetryAfter {
		if d, ok := RetryAfter(resp.Header); ok {
			return d
		}
	}
	return p.Backoff(attempt)
}

func (p RetryPolicy) sleepFn() func(time.Duration) {
	if p.sleep != nil {
		return p.sleep
	}
	return time.Sleep
}

func (p RetryPolicy) nowFn() func() time.Time {
	if p.now != nil {
		return p.now
	}
	return time.Now
}
