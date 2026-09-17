// Package typesafe is an unofficial Go client for the TypeSafe AI API.
// It is not affiliated with or endorsed by TypeSafe AI.
//
// TypeSafe's System One models answer typed questions about a piece of
// state and return calibrated probabilities. Three question types exist:
// Noul (yes or no), Choice (one option from a set), and Score (a position
// on an ordered scale).
//
//	client, err := typesafe.New(typesafe.WithAPIKey(os.Getenv("TYPESAFE_API_KEY")))
//	if err != nil {
//		log.Fatal(err)
//	}
//
//	res, err := client.Evaluate(ctx, "Help! My payouts have been failing for 3 days.",
//		typesafe.Questions{
//			"urgent": typesafe.Noul("Does this convey urgency?"),
//			"dept": typesafe.Choice("Which team should handle this?",
//				typesafe.Opt("billing", "Payments, invoicing, refunds"),
//				typesafe.Opt("technical", "Bugs, outages, integrations"),
//				typesafe.Opt("sales", nil),
//			),
//			"anger": typesafe.Score("How frustrated is the customer?",
//				"Calm", "Frustrated", "Very angry"),
//		})
//	if err != nil {
//		var apiErr *typesafe.Error
//		if errors.As(err, &apiErr) && apiErr.Type == typesafe.ErrRateLimited {
//			// back off using apiErr.RetryAfter
//		}
//		return err
//	}
//
//	dept := res.Choice("dept")     // *ChoiceAnswer or nil
//	fmt.Println(dept.Choice, dept.Confidence)
//
// Two layers: the typed API above, and a raw layer (Client.Post, Client.Get,
// Client.Do) that speaks map[string]any for parts of the API this package
// does not model yet.
package typesafe
