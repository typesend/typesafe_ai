package typesafe_test

import (
	"context"
	"errors"
	"fmt"
	"testing"

	typesafe "github.com/typesend/typesafe_ai"
	"github.com/typesend/typesafe_ai/typesafetest"
)

// Example_readme runs the README example against typesafetest stubs.
func Example_readme() {
	t := &testing.T{}
	srv := typesafetest.NewServer(t)
	srv.Stub(typesafetest.Answers{
		"urgent": typesafetest.NoulOf(0.92),
		"dept":   typesafetest.ChoiceOf("technical", 0.82),
		"anger":  typesafetest.ScoreOf(2, 0.65),
	})
	client := srv.Client()

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
		var apiErr *typesafe.Error
		if errors.As(err, &apiErr) {
			fmt.Println(apiErr.Type, apiErr.RequestID)
		}
		return
	}
	fmt.Println(res.Noul("urgent").Yes(0.5))
	fmt.Println(res.Choice("dept").Choice, res.Choice("dept").Confidence())
	fmt.Println(res.Score("anger").Level, res.Score("anger").Label)
	fmt.Println(typesafe.Gate(res.Choice("dept"), 0.8, 0.5), typesafe.Gate(res.Score("anger"), 0.8, 0.5))
	// Output:
	// true
	// technical 0.82
	// 2 Very angry
	// act review
}
