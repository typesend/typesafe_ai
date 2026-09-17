package typesafe_test

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"

	typesafe "github.com/typesend/typesafe_ai"
	"github.com/typesend/typesafe_ai/typesafetest"
)

// stubServer starts a minimal TypeSafe stand-in that does not need a
// *testing.T: it answers every /v1/systemone request with the answers fn
// returns for that state. Examples run through go test's Example machinery,
// which has no testing.T to hand them, so they cannot use
// typesafetest.NewServer (which requires one).
func stubServer(fn func(state string) map[string]any) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			State any    `json:"state"`
			Model string `json:"model"`
		}
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &req)
		state, _ := req.State.(string)
		typesafetest.JSON(w, http.StatusOK, map[string]any{
			"model":   req.Model,
			"answers": fn(state),
			"usage":   map[string]any{"input_tokens": 10, "output_tokens": 5},
		})
	}))
}

// ExampleClient_Evaluate asks three questions about a single piece of state.
func ExampleClient_Evaluate() {
	srv := stubServer(func(state string) map[string]any {
		return map[string]any{
			"urgent": map[string]any{"type": "noul", "noul": 0.92},
			"dept": map[string]any{
				"type": "choice", "choice": "technical", "confidence": 0.82,
				"probabilities": map[string]float64{"billing": 0.08, "technical": 0.82, "sales": 0.1},
			},
			"anger": map[string]any{
				"type": "score", "score": 1.6, "confidence": 0.65,
				"probabilities": map[string]float64{"0": 0.05, "1": 0.3, "2": 0.65},
			},
		}
	})
	defer srv.Close()

	client, err := typesafe.New(typesafe.WithAPIKey("test-key"), typesafe.WithBaseURL(srv.URL))
	if err != nil {
		fmt.Println(err)
		return
	}

	res, err := client.Evaluate(context.Background(), "Help! My payouts have been failing for 3 days.",
		typesafe.Questions{
			"urgent": typesafe.Noul("Does this convey urgency?"),
			"dept": typesafe.Choice("Which team should handle this?",
				typesafe.Opt("billing", "Payments, invoicing, refunds"),
				typesafe.Opt("technical", "Bugs, outages, integrations"),
				typesafe.Opt("sales", nil)),
			"anger": typesafe.Score("How frustrated is the customer?", "Calm", "Frustrated", "Very angry"),
		})
	if err != nil {
		fmt.Println(err)
		return
	}
	fmt.Println(res.Noul("urgent").Yes(0.5))
	fmt.Println(res.Choice("dept").Choice)
	fmt.Println(res.Score("anger").Level, res.Score("anger").Label)
	fmt.Println(typesafe.Gate(res.Choice("dept"), 0.8, 0.5))
	// Output:
	// true
	// technical
	// 2 Very angry
	// act
}

// ExampleClient_EvaluateMany evaluates several states against one question
// set concurrently.
func ExampleClient_EvaluateMany() {
	srv := stubServer(func(state string) map[string]any {
		positive := 0.9
		if strings.Contains(state, "broke") {
			positive = 0.1
		}
		return map[string]any{"positive": map[string]any{"type": "noul", "noul": positive}}
	})
	defer srv.Close()

	client, err := typesafe.New(typesafe.WithAPIKey("test-key"), typesafe.WithBaseURL(srv.URL))
	if err != nil {
		fmt.Println(err)
		return
	}

	states := []typesafe.State{"Great product, works well.", "This broke on day one."}
	outcomes, err := client.EvaluateMany(context.Background(), states,
		typesafe.Questions{"positive": typesafe.Noul("Is this review positive?")},
		typesafe.ManyOptions{MaxConcurrency: 2})
	if err != nil {
		fmt.Println(err)
		return
	}
	for i, o := range outcomes {
		if o.Err != nil {
			fmt.Println(i, "error:", o.Err.Type)
			continue
		}
		fmt.Println(i, o.Result.Noul("positive").Yes(0.5))
	}
	// Output:
	// 0 true
	// 1 false
}

// ExampleGate shows the three verdicts Gate can return, driven only by an
// answer's Confidence.
func ExampleGate() {
	confident := &typesafe.NoulAnswer{Noul: 0.92} // Confidence 0.92
	middling := &typesafe.NoulAnswer{Noul: 0.78}  // Confidence 0.78
	unsure := &typesafe.NoulAnswer{Noul: 0.55}    // Confidence 0.55

	fmt.Println(typesafe.Gate(confident, 0.9, 0.7))
	fmt.Println(typesafe.Gate(middling, 0.9, 0.7))
	fmt.Println(typesafe.Gate(unsure, 0.9, 0.7))
	// Output:
	// act
	// review
	// escalate
}
