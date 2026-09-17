package typesafe

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// fakeClock advances only when the policy sleeps, so retry tests never wait.
type fakeClock struct {
	now    time.Time
	sleeps []time.Duration
}

func (f *fakeClock) policy(p RetryPolicy) RetryPolicy {
	p.now = func() time.Time { return f.now }
	p.sleep = func(d time.Duration) { f.sleeps = append(f.sleeps, d); f.now = f.now.Add(d) }
	return p
}

func newTestClient(t *testing.T, srv *httptest.Server, p RetryPolicy) *Client {
	t.Helper()
	c, err := New(WithAPIKey("k"), WithBaseURL(srv.URL), WithRetry(p))
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func sequence(t *testing.T, statuses []int, headers ...http.Header) (*httptest.Server, *int32) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := int(atomic.AddInt32(&calls, 1)) - 1
		if n >= len(statuses) {
			n = len(statuses) - 1
		}
		if n < len(headers) {
			for k, vs := range headers[n] {
				for _, v := range vs {
					w.Header().Add(k, v)
				}
			}
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(statuses[n])
		if statuses[n] == 200 {
			_, _ = w.Write([]byte(`{"ok":true}`))
		} else {
			_, _ = w.Write([]byte(`{"error":"nope"}`))
		}
	}))
	t.Cleanup(srv.Close)
	return srv, &calls
}

func TestDefaultPolicyMirrorsOfficialSDK(t *testing.T) {
	p := DefaultRetryPolicy()
	if p.MaxRetries != 2 || p.BackoffInitial != 500*time.Millisecond || p.BackoffMax != 5*time.Second ||
		p.BackoffJitter != 0.25 || p.Budget != 30*time.Second || !p.RespectRetryAfter {
		t.Fatalf("unexpected defaults: %+v", p)
	}
	for _, s := range []int{408, 429, 500, 529, 599} {
		if !p.retryableStatus(s) {
			t.Errorf("%d should be retryable", s)
		}
	}
	if p.retryableStatus(422) {
		t.Error("422 must not be retryable")
	}
}

func TestBackoffDoublesWithJitterBounds(t *testing.T) {
	p := DefaultRetryPolicy()
	expected := map[int]time.Duration{1: 500 * time.Millisecond, 2: time.Second, 3: 2 * time.Second, 4: 4 * time.Second, 5: 5 * time.Second, 9: 5 * time.Second}
	for attempt, exp := range expected {
		for i := 0; i < 200; i++ {
			d := p.Backoff(attempt)
			if d > exp || d < time.Duration(float64(exp)*0.75) {
				t.Fatalf("attempt %d: delay %v outside [%v, %v]", attempt, d, time.Duration(float64(exp)*0.75), exp)
			}
		}
	}
	p.BackoffJitter = 0
	if p.Backoff(3) != 2*time.Second {
		t.Fatalf("zero jitter should be deterministic, got %v", p.Backoff(3))
	}
	p.BackoffInitial = 0
	if p.Backoff(3) != 0 {
		t.Fatal("zero initial disables backoff")
	}
}

func TestRetryAfterParsing(t *testing.T) {
	h := func(kv ...string) http.Header {
		out := http.Header{}
		for i := 0; i < len(kv); i += 2 {
			out.Set(kv[i], kv[i+1])
		}
		return out
	}
	cases := []struct {
		name string
		h    http.Header
		want time.Duration
		ok   bool
	}{
		{"seconds", h("Retry-After", "2"), 2 * time.Second, true},
		{"fractional seconds", h("Retry-After", "0.25"), 250 * time.Millisecond, true},
		{"ms beats seconds", h("retry-after-ms", "750", "Retry-After", "9"), 750 * time.Millisecond, true},
		{"negative", h("Retry-After", "-1"), 0, false},
		{"garbage", h("Retry-After", "soon"), 0, false},
		{"garbage ms", h("retry-after-ms", "nope"), 0, false},
		{"absent", h(), 0, false},
		{"past date", h("Retry-After", "Wed, 21 Oct 2015 07:28:00 GMT"), 0, true},
	}
	for _, c := range cases {
		got, ok := RetryAfter(c.h)
		if ok != c.ok || got != c.want {
			t.Errorf("%s: got (%v, %v) want (%v, %v)", c.name, got, ok, c.want, c.ok)
		}
	}
	future := time.Now().Add(90 * time.Second).UTC().Format(http.TimeFormat)
	got, ok := RetryAfter(h("Retry-After", future))
	if !ok || got < 85*time.Second || got > 90*time.Second {
		t.Errorf("http date: got %v %v", got, ok)
	}
}

func TestRetriesThenSucceeds(t *testing.T) {
	srv, calls := sequence(t, []int{529, 200})
	var retryHeader atomic.Value
	inner := srv.Config.Handler
	srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if v := r.Header.Get("X-TypeSafe-Retry-Count"); v != "" {
			retryHeader.Store(v)
		}
		inner.ServeHTTP(w, r)
	})
	clock := &fakeClock{}
	p := clock.policy(DefaultRetryPolicy())
	p.BackoffJitter = 0
	c := newTestClient(t, srv, p)

	resp, err := c.Do(context.Background(), http.MethodPost, "/x", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	if resp.RetryCount != 1 || *calls != 2 {
		t.Fatalf("retry count %d, calls %d", resp.RetryCount, *calls)
	}
	if len(clock.sleeps) != 1 || clock.sleeps[0] != 500*time.Millisecond {
		t.Fatalf("sleeps %v", clock.sleeps)
	}
	if retryHeader.Load() != "1" {
		t.Fatalf("retry header %v", retryHeader.Load())
	}
}

func TestRetryHonoursRetryAfterAndMsPrecedence(t *testing.T) {
	srv, _ := sequence(t, []int{429, 200}, http.Header{"Retry-After": {"2"}})
	clock := &fakeClock{}
	c := newTestClient(t, srv, clock.policy(DefaultRetryPolicy()))
	if _, err := c.Get(context.Background(), "/x"); err != nil {
		t.Fatal(err)
	}
	if len(clock.sleeps) != 1 || clock.sleeps[0] != 2*time.Second {
		t.Fatalf("sleeps %v", clock.sleeps)
	}

	srv2, _ := sequence(t, []int{429, 200}, http.Header{"Retry-After-Ms": {"120"}, "Retry-After": {"5"}})
	clock2 := &fakeClock{}
	c2 := newTestClient(t, srv2, clock2.policy(DefaultRetryPolicy()))
	if _, err := c2.Get(context.Background(), "/x"); err != nil {
		t.Fatal(err)
	}
	if len(clock2.sleeps) != 1 || clock2.sleeps[0] != 120*time.Millisecond {
		t.Fatalf("sleeps %v", clock2.sleeps)
	}
}

func TestGivesUpAfterMaxRetries(t *testing.T) {
	srv, calls := sequence(t, []int{529})
	clock := &fakeClock{}
	p := clock.policy(DefaultRetryPolicy())
	p.BackoffJitter = 0
	c := newTestClient(t, srv, p)
	_, err := c.Get(context.Background(), "/x")
	e, ok := err.(*Error)
	if !ok || e.Type != ErrOverloaded || e.Status != 529 {
		t.Fatalf("got %v", err)
	}
	if *calls != 3 || len(clock.sleeps) != 2 || clock.sleeps[1] != time.Second {
		t.Fatalf("calls %d sleeps %v", *calls, clock.sleeps)
	}
}

func TestDoesNotRetryValidation(t *testing.T) {
	srv, calls := sequence(t, []int{422})
	clock := &fakeClock{}
	c := newTestClient(t, srv, clock.policy(DefaultRetryPolicy()))
	_, err := c.Get(context.Background(), "/x")
	if e := err.(*Error); e.Type != ErrValidation || *calls != 1 || len(clock.sleeps) != 0 {
		t.Fatalf("got %v calls %d sleeps %v", err, *calls, clock.sleeps)
	}
}

func TestBudgetStopsBeforeExceeding(t *testing.T) {
	// Repeated 529s with Retry-After: 20 and a 30s budget: the first retry
	// fits (0 + 20 < 30), the second would land at 40s, so we stop.
	srv, calls := sequence(t, []int{529}, http.Header{"Retry-After": {"20"}})
	clock := &fakeClock{}
	p := clock.policy(DefaultRetryPolicy())
	p.MaxRetries = 10
	c := newTestClient(t, srv, p)
	_, err := c.Get(context.Background(), "/x")
	e := err.(*Error)
	if e.Type != ErrOverloaded || e.RetryAfter != 20*time.Second {
		t.Fatalf("got %v", err)
	}
	if *calls != 2 || len(clock.sleeps) != 1 || clock.now.Sub(time.Time{}) >= 30*time.Second {
		t.Fatalf("calls %d sleeps %v elapsed %v", *calls, clock.sleeps, clock.now.Sub(time.Time{}))
	}
}

func TestBudgetDisabledWithZero(t *testing.T) {
	srv, _ := sequence(t, []int{529, 200}, http.Header{"Retry-After": {"100"}})
	clock := &fakeClock{}
	p := clock.policy(DefaultRetryPolicy())
	p.Budget = 0
	c := newTestClient(t, srv, p)
	if _, err := c.Get(context.Background(), "/x"); err != nil {
		t.Fatal(err)
	}
	if clock.sleeps[0] != 100*time.Second {
		t.Fatalf("sleeps %v", clock.sleeps)
	}
}

func TestRetriesConnectionAndTimeoutErrors(t *testing.T) {
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if atomic.AddInt32(&calls, 1) == 1 {
			time.Sleep(400 * time.Millisecond) // exceeds the 50ms attempt timeout
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	t.Cleanup(srv.Close)
	clock := &fakeClock{}
	p := clock.policy(DefaultRetryPolicy())
	c, _ := New(WithAPIKey("k"), WithBaseURL(srv.URL), WithRetry(p), WithTimeout(50*time.Millisecond))
	if _, err := c.Get(context.Background(), "/x"); err != nil {
		t.Fatalf("timeout should be retried: %v", err)
	}

	p.RetryTimeoutErrors = false
	atomic.StoreInt32(&calls, 0)
	c2, _ := New(WithAPIKey("k"), WithBaseURL(srv.URL), WithRetry(p), WithTimeout(50*time.Millisecond))
	_, err := c2.Get(context.Background(), "/x")
	if e, ok := err.(*Error); !ok || e.Type != ErrTimeout {
		t.Fatalf("expected timeout error, got %v", err)
	}

	// connection refused
	dead := httptest.NewServer(http.NotFoundHandler())
	dead.Close()
	c3, _ := New(WithAPIKey("k"), WithBaseURL(dead.URL), WithRetry(NoRetry()))
	_, err = c3.Get(context.Background(), "/x")
	if e, ok := err.(*Error); !ok || e.Type != ErrConnection {
		t.Fatalf("expected connection error, got %v", err)
	}
}

func TestCallerContextCancellationIsNotRetried(t *testing.T) {
	srv, calls := sequence(t, []int{529})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	c := newTestClient(t, srv, DefaultRetryPolicy())
	_, err := c.Get(ctx, "/x")
	if err == nil || *calls != 0 {
		t.Fatalf("err %v calls %d", err, *calls)
	}
}
