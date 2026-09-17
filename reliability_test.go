package typesafe_test

import (
	"context"
	"net"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	typesafe "github.com/typesend/typesafe_ai"
	"github.com/typesend/typesafe_ai/typesafetest"
)

func TestRetrySleepStopsOnContextCancel(t *testing.T) {
	srv := typesafetest.NewServer(t)
	srv.StubError(529, map[string]any{}, http.Header{"Retry-After": {"30"}})
	p := typesafe.DefaultRetryPolicy()
	p.Budget = 0 // would otherwise refuse the 30s wait
	client := srv.Client(typesafe.WithRetry(p))
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := client.Evaluate(ctx, "x", typesafe.Questions{"q": typesafe.Noul("?")})
	if time.Since(start) > 2*time.Second {
		t.Fatal("retry sleep ignored context cancellation")
	}
	e, ok := err.(*typesafe.Error)
	if !ok || !strings.Contains(e.Message, "waiting to retry") {
		t.Fatalf("expected cancelled-while-waiting error, got %v", err)
	}
}

func TestDefaultTransportKeepsConnectionsAlive(t *testing.T) {
	var conns int32
	srv := typesafetest.NewServer(t)
	srv.Stub(typesafetest.Answers{"q": typesafetest.NoulOf(0.5)})
	client := srv.Client(typesafe.WithHTTPClient(&http.Client{Transport: countingTransport(&conns)}))
	states := make([]typesafe.State, 40)
	for i := range states {
		states[i] = "s"
	}
	if _, err := client.EvaluateMany(context.Background(), states, typesafe.Questions{"q": typesafe.Noul("?")}, typesafe.ManyOptions{MaxConcurrency: 8}); err != nil {
		t.Fatal(err)
	}
	// With keep-alive, 40 requests at concurrency 8 need about 8 connections;
	// goroutines racing for the idle pool can open a few more. Without pooling
	// (Go's default of 2 idle per host) this climbs toward 40.
	if n := atomic.LoadInt32(&conns); n > 16 {
		t.Fatalf("opened %d connections for 40 requests at concurrency 8; pooling is broken", n)
	}
}

func countingTransport(conns *int32) *http.Transport {
	tr := typesafe.DefaultTransport()
	dial := tr.DialContext
	tr.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		atomic.AddInt32(conns, 1)
		return dial(ctx, network, addr)
	}
	return tr
}

func TestPerStateTimeoutAndPanicIsolation(t *testing.T) {
	srv := typesafetest.NewServer(t)
	srv.Handle(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(string(mustRead(r)), "slow") {
			time.Sleep(500 * time.Millisecond)
		}
		typesafetest.JSON(w, 200, map[string]any{"model": "m",
			"answers": map[string]any{"q": map[string]any{"type": "noul", "noul": 0.5}},
			"usage":   map[string]any{"input_tokens": 1, "output_tokens": 1}})
	})
	calls := 0
	hooks := typesafe.Hooks{OnResponse: func(i typesafe.ResponseInfo) {
		calls++
		if calls == 1 {
			panic("hook bug")
		}
	}}
	client := srv.Client(typesafe.WithHooks(hooks))
	outcomes, err := client.EvaluateMany(context.Background(), []typesafe.State{"fast", "slow", "fast"},
		typesafe.Questions{"q": typesafe.Noul("?")}, typesafe.ManyOptions{MaxConcurrency: 1, Timeout: 100 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	if outcomes[0].Err != nil || outcomes[2].Err != nil {
		t.Fatalf("hook panic or slow state leaked into other outcomes: %+v", outcomes)
	}
	if outcomes[1].Err == nil || outcomes[1].Err.Type != typesafe.ErrTimeout {
		t.Fatalf("slow state should time out: %+v", outcomes[1])
	}
}

func TestResponseBodyIsBounded(t *testing.T) {
	srv := typesafetest.NewServer(t)
	srv.Handle(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"pad":"` + strings.Repeat("x", 5000) + `"}`))
	})
	client := srv.Client(typesafe.WithMaxResponseBytes(1024))
	_, err := client.Get(context.Background(), "/v1/models")
	e, ok := err.(*typesafe.Error)
	if !ok || e.Type != typesafe.ErrUnexpected || !strings.Contains(e.Message, "exceeds 1024 bytes") {
		t.Fatalf("got %v", err)
	}
}

func mustRead(r *http.Request) []byte {
	b := make([]byte, 4096)
	n, _ := r.Body.Read(b)
	return b[:n]
}
