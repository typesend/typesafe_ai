package typesafetest_test

import (
	"context"
	"errors"
	"net/http"
	"testing"

	typesafe "github.com/typesend/typesafe_ai"
	"github.com/typesend/typesafe_ai/typesafetest"
)

// TestExampleStub demonstrates typesafetest.Server.Stub. It is written as a
// test rather than a runnable Example because Server.Stub needs a real
// *testing.T (for t.Cleanup and to fail the test on an unstubbed question),
// and an Example function has no testing.T to give it.
func TestExampleStub(t *testing.T) {
	srv := typesafetest.NewServer(t)
	srv.Stub(typesafetest.Answers{
		"dept":   typesafetest.ChoiceOf("billing", 0.9),
		"urgent": typesafetest.NoulOf(0.3),
		"anger":  typesafetest.ScoreOf(1, 0.8),
	})
	client := srv.Client()

	res, err := client.Evaluate(context.Background(), "Where is my refund?", typesafe.Questions{
		"dept": typesafe.Choice("Which team should handle this?",
			typesafe.Opt("billing", nil), typesafe.Opt("technical", nil)),
		"urgent": typesafe.Noul("Does this convey urgency?"),
		"anger":  typesafe.Score("How frustrated is the customer?", "Calm", "Frustrated", "Very angry"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := res.Choice("dept").Choice; got != "billing" {
		t.Errorf("dept = %q, want billing", got)
	}
	if got := res.Score("anger").Level; got != 1 {
		t.Errorf("anger level = %d, want 1 (Frustrated)", got)
	}
}

// TestExampleStubError demonstrates typesafetest.Server.StubError, and that
// RetryAfter survives past the retries it caused.
func TestExampleStubError(t *testing.T) {
	srv := typesafetest.NewServer(t)
	srv.StubError(429, map[string]any{"error": "slow down"}, http.Header{"Retry-After": {"0"}})
	client := srv.Client(typesafe.WithRetry(typesafe.RetryPolicy{MaxRetries: 1}))

	_, err := client.Evaluate(context.Background(), "x", typesafe.Questions{
		"q": typesafe.Noul("?"),
	})
	var apiErr *typesafe.Error
	if !errors.As(err, &apiErr) {
		t.Fatalf("got %v, want *typesafe.Error", err)
	}
	if apiErr.Type != typesafe.ErrRateLimited {
		t.Errorf("Type = %v, want ErrRateLimited", apiErr.Type)
	}
	if apiErr.RetryAfter != 0 {
		t.Errorf("RetryAfter = %v, want 0 (server asked for none)", apiErr.RetryAfter)
	}
}
