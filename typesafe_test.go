package typesafe_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	typesafe "github.com/typesend/typesafe_ai"
	"github.com/typesend/typesafe_ai/typesafetest"
)

var readmeQuestions = typesafe.Questions{
	"urgent": typesafe.Noul("Does this convey urgency?",
		typesafe.WhenTrue("Explicitly time-sensitive"), typesafe.WhenFalse("No urgency expressed")),
	"dept": typesafe.Choice("Which team should handle this?",
		typesafe.Opt("billing", "Payments, invoicing, refunds"),
		typesafe.Opt("technical", "Bugs, outages, integrations"),
		typesafe.Opt("sales", nil)),
	"anger": typesafe.Score("How frustrated is the customer?", "Calm", "Frustrated", "Very angry"),
}

// The API reference example response.
var readmeResponse = map[string]any{
	"model": "jev-1.13.0",
	"answers": map[string]any{
		"urgent": map[string]any{"type": "noul", "noul": 0.92},
		"dept": map[string]any{"type": "choice", "choice": "technical",
			"probabilities": map[string]any{"billing": 0.08, "technical": 0.85, "sales": 0.07}, "confidence": 0.82},
		"anger": map[string]any{"type": "score", "score": 1.6,
			"legend":        map[string]any{"0": "Calm", "1": "Frustrated", "2": "Very angry"},
			"probabilities": map[string]any{"0": 0.05, "1": 0.3, "2": 0.65}, "confidence": 0.78},
	},
	"usage": map[string]any{"input_tokens": 312, "output_tokens": 48},
}

func TestNewResolvesConfig(t *testing.T) {
	for _, k := range []string{typesafe.EnvAPIKey, typesafe.EnvBaseURL, typesafe.EnvDefaultModel} {
		t.Setenv(k, "")
	}
	if _, err := typesafe.New(); err == nil || !strings.Contains(err.Error(), typesafe.EnvAPIKey) {
		t.Fatalf("expected missing key error, got %v", err)
	}
	t.Setenv(typesafe.EnvAPIKey, "env-key")
	t.Setenv(typesafe.EnvBaseURL, "https://example.test/")
	t.Setenv(typesafe.EnvDefaultModel, "jev-env")
	c, err := typesafe.New()
	if err != nil {
		t.Fatal(err)
	}
	if c.BaseURL() != "https://example.test" || c.Model() != "jev-env" || c.Timeout() != 10*time.Second {
		t.Fatalf("resolved %v", c)
	}
	c2, _ := typesafe.New(typesafe.WithAPIKey("secret"), typesafe.WithModel("jev-x"))
	if c2.Model() != "jev-x" || strings.Contains(fmt.Sprintf("%v %#v %s", c2, c2, c2), "secret") {
		t.Fatalf("options or redaction broken: %v", c2)
	}
	if _, err := typesafe.New(typesafe.WithAPIKey("k"), typesafe.WithRetry(typesafe.RetryPolicy{BackoffJitter: 2})); err == nil {
		t.Fatal("expected invalid retry policy error")
	}
	partial, _ := typesafe.New(typesafe.WithAPIKey("k"), typesafe.WithRetry(typesafe.RetryPolicy{MaxRetries: 5}))
	if partial.Retry().Budget != 30*time.Second || len(partial.Retry().Statuses) == 0 {
		t.Fatalf("partial retry literal lost defaults: %+v", partial.Retry())
	}
}

func TestEvaluateStreamYieldsAsCompletedAndStopsEarly(t *testing.T) {
	srv := typesafetest.NewServer(t)
	srv.Handle(func(w http.ResponseWriter, r *http.Request) {
		var body struct{ State string }
		raw, _ := json.Marshal(mustBody(r))
		_ = json.Unmarshal(raw, &body)
		var n float64
		_, _ = fmt.Sscanf(body.State, "%f", &n)
		time.Sleep(time.Duration(n) * time.Millisecond)
		typesafetest.JSON(w, 200, map[string]any{"model": "m",
			"answers": map[string]any{"q": map[string]any{"type": "noul", "noul": n / 100}},
			"usage":   map[string]any{"input_tokens": 1, "output_tokens": 1}})
	})
	client := srv.Client()
	var pulled atomic.Int32 // incremented on the feeder goroutine
	states := func(yield func(typesafe.State) bool) {
		delays := append([]string{"60", "5", "40", "10", "80", "1"}, make([]string, 40)...)
		for i := range delays[6:] {
			delays[6+i] = "1"
		}
		for _, s := range delays {
			pulled.Add(1)
			if !yield(s) {
				return
			}
		}
	}
	var order []int
	for i, o := range client.EvaluateStream(context.Background(), states, typesafe.Questions{"q": typesafe.Noul("?")}, typesafe.ManyOptions{MaxConcurrency: 2}) {
		if o.Err != nil {
			t.Fatal(o.Err)
		}
		order = append(order, i)
		if len(order) == 3 {
			break // stop early: remaining states must not all be pulled
		}
	}
	if len(order) != 3 || order[0] == 0 {
		t.Fatalf("expected completion order with the slow first state not first, got %v", order)
	}
	if pulled.Load() >= 46 {
		t.Fatal("iterator was drained despite early stop")
	}
	var bad []int
	for i := range client.EvaluateStream(context.Background(), states, typesafe.Questions{}) {
		bad = append(bad, i)
	}
	if len(bad) != 1 || bad[0] != -1 {
		t.Fatalf("invalid question set should yield one index -1 outcome, got %v", bad)
	}
}

func TestCallMetadataReachesHooks(t *testing.T) {
	var got map[string]any
	srv := typesafetest.NewServer(t)
	srv.Stub(typesafetest.Answers{"q": typesafetest.NoulOf(0.5)})
	client := srv.Client(typesafe.WithHooks(typesafe.Hooks{OnResponse: func(i typesafe.ResponseInfo) { got = i.Metadata }}))
	_, err := client.Evaluate(context.Background(), "x", typesafe.Questions{"q": typesafe.Noul("?")}, typesafe.CallOptions{Metadata: map[string]any{"tenant": "acme"}})
	if err != nil || got["tenant"] != "acme" {
		t.Fatalf("metadata %v err %v", got, err)
	}
}

func TestStateValidationRejectsAllScalars(t *testing.T) {
	srv := typesafetest.NewServer(t)
	client := srv.Client()
	for _, bad := range []typesafe.State{int32(7), uint(1), float32(2), true, nil} {
		_, err := client.Evaluate(context.Background(), bad, typesafe.Questions{"q": typesafe.Noul("?")})
		if e, ok := err.(*typesafe.Error); !ok || e.Type != typesafe.ErrValidation {
			t.Errorf("%T should be rejected, got %v", bad, err)
		}
	}
	type payload struct{ Text string }
	srv.Stub(typesafetest.Answers{"q": typesafetest.NoulOf(0.5)})
	if _, err := client.Evaluate(context.Background(), payload{"hi"}, typesafe.Questions{"q": typesafe.Noul("?")}); err != nil {
		t.Errorf("structs should be accepted: %v", err)
	}
}

func TestEvaluateSendsDocumentedBodyAndDecodesExample(t *testing.T) {
	srv := typesafetest.NewServer(t)
	srv.Handle(func(w http.ResponseWriter, r *http.Request) { typesafetest.JSON(w, 200, readmeResponse) })
	client := srv.Client()

	res, err := client.Evaluate(context.Background(), "Help! My payouts have been failing for 3 days.", readmeQuestions)
	if err != nil {
		t.Fatal(err)
	}
	req := srv.Requests()[0]
	if req.Method != "POST" || req.URL.Path != "/v1/systemone" || req.Header.Get("Authorization") != "Bearer test-key" ||
		req.Header.Get("User-Agent") != "typesafe_ai-go/"+typesafe.Version+" (Go)" || req.Header.Get("Content-Type") != "application/json" {
		t.Fatalf("request shape wrong: %v %v", req.URL, req.Header)
	}
	var body map[string]any
	_ = json.Unmarshal(srv.Bodies()[0], &body)
	if body["state"] != "Help! My payouts have been failing for 3 days." || body["model"] != "jev-latest" {
		t.Fatalf("body %v", body)
	}
	qs := body["questions"].(map[string]any)
	dept := qs["dept"].(map[string]any)
	if dept["type"] != "choice" || dept["criteria"].(map[string]any)["sales"] != nil {
		t.Fatalf("dept %v", dept)
	}
	raw := string(srv.Bodies()[0])
	if strings.Index(raw, `"billing":`) > strings.Index(raw, `"technical":`) || strings.Index(raw, `"technical":`) > strings.Index(raw, `"sales":`) {
		t.Fatal("choice options not in caller order on the wire")
	}

	if res.Model != "jev-1.13.0" || res.Usage != (typesafe.Usage{InputTokens: 312, OutputTokens: 48}) {
		t.Fatalf("result %+v", res)
	}
	if u := res.Noul("urgent"); u == nil || u.Noul != 0.92 || !u.Yes(0.5) {
		t.Fatalf("urgent %+v", u)
	}
	d := res.Choice("dept")
	if d == nil || d.Choice != "technical" || d.Confidence() != 0.82 || d.Probabilities["billing"] != 0.08 {
		t.Fatalf("dept %+v", d)
	}
	a := res.Score("anger")
	if a == nil || a.Score != 1.6 || a.Level != 2 || a.Label != "Very angry" || a.Description != "Very angry" || a.Confidence() != 0.78 {
		t.Fatalf("anger %+v", a)
	}
	if len(a.Levels) != 3 || a.Levels[0] != (typesafe.LevelProbability{"Calm", 0.05}) || a.Levels[2].Probability != 0.65 {
		t.Fatalf("levels %+v", a.Levels)
	}
	if a.Probabilities[1] != 0.3 || a.Legend[2] != "Very angry" || a.Normalized() != 0.8 {
		t.Fatalf("score fields %+v", a)
	}
	if typesafe.Gate(d, 0.8, 0.5) != typesafe.GateAct || typesafe.Gate(a, 0.8, 0.5) != typesafe.GateReview {
		t.Fatal("gate verdicts wrong")
	}
	if res.Noul("dept") != nil || res.Choice("missing") != nil {
		t.Fatal("typed accessors should return nil on mismatch")
	}
}

func TestChoiceOrderSurvivesFortyOptions(t *testing.T) {
	opts := make([]typesafe.ChoiceOption, 40)
	for i := range opts {
		n := (i*17)%41 + 1 // a permutation of 1..40 that is not sorted
		opts[i] = typesafe.Opt(fmt.Sprintf("option_%d", n), fmt.Sprintf("Description %d", n))
	}
	srv := typesafetest.NewServer(t)
	srv.Stub(typesafetest.Answers{"q": typesafetest.ChoiceOf(opts[0].Key, 0.9)})
	if _, err := srv.Client().Evaluate(context.Background(), "pick", typesafe.Questions{"q": typesafe.Choice("Which?", opts...)}); err != nil {
		t.Fatal(err)
	}
	raw := string(srv.Bodies()[0])
	last := -1
	for _, o := range opts {
		idx := strings.Index(raw, `"`+o.Key+`":`)
		if idx < 0 || idx < last {
			t.Fatalf("option %s out of order on the wire", o.Key)
		}
		last = idx
	}
}

func TestLocalValidation(t *testing.T) {
	srv := typesafetest.NewServer(t) // no stub: any request fails the test
	client := srv.Client()
	cases := map[string]typesafe.Questions{
		"one level":       {"s": typesafe.Score("?", "only")},
		"eleven levels":   {"s": typesafe.Score("?", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11")},
		"one option":      {"c": typesafe.ChoiceKeys("?", "a")},
		"256 options":     {"c": typesafe.ChoiceKeys("?", manyKeys(256)...)},
		"duplicate":       {"c": typesafe.ChoiceKeys("?", "a", "a")},
		"nil instruction": {"n": typesafe.Noul(nil)},
		"empty":           {},
		"empty id":        {"": typesafe.Noul("?")},
	}
	for name, qs := range cases {
		_, err := client.Evaluate(context.Background(), "x", qs)
		var e *typesafe.Error
		if !errors.As(err, &e) || e.Type != typesafe.ErrValidation || e.Status != 0 {
			t.Errorf("%s: expected local validation error, got %v", name, err)
		}
	}
	if _, err := client.Evaluate(context.Background(), 42, typesafe.Questions{"n": typesafe.Noul("?")}); err == nil {
		t.Error("numeric state should be rejected")
	}
	if err := (typesafe.Questions{"c": typesafe.ChoiceKeys("?", manyKeys(255)...)}).Validate(); err != nil {
		t.Errorf("255 options should be valid: %v", err)
	}
}

func manyKeys(n int) []string {
	keys := make([]string, n)
	for i := range keys {
		keys[i] = fmt.Sprintf("opt_%d", i)
	}
	return keys
}

func TestStructuredLevelsAndLabels(t *testing.T) {
	srv := typesafetest.NewServer(t)
	srv.Stub(typesafetest.Answers{"sev": typesafetest.ScoreOf(1, 0.8)})
	blocking := map[string]any{"what": "Blocking", "examples": []any{"nobody can log in"}}
	qs := typesafe.Questions{"sev": typesafe.ScoreLevels("Severity?",
		typesafe.ScoreLevel{Description: map[string]any{"what": "Cosmetic"}},
		typesafe.Level("Degraded", "Broken feature, workaround exists"),
		typesafe.ScoreLevel{Description: blocking},
	)}
	res, err := srv.Client().Evaluate(context.Background(), "x", qs)
	if err != nil {
		t.Fatal(err)
	}
	s := res.Score("sev")
	if s.Label != "Degraded" || s.Description != "Broken feature, workaround exists" {
		t.Fatalf("labelled level: %+v", s)
	}
	if !strings.Contains(s.Levels[0].Label, "Cosmetic") || !strings.Contains(s.Levels[2].Label, "Blocking") {
		t.Fatalf("structured labels: %+v", s.Levels)
	}
	var body map[string]any
	_ = json.Unmarshal(srv.Bodies()[0], &body)
	criteria := body["questions"].(map[string]any)["sev"].(map[string]any)["criteria"].([]any)
	if criteria[1].(map[string]any)["label"] != "Degraded" {
		t.Fatalf("labelled level wire shape: %v", criteria[1])
	}
}

func TestErrorMapping(t *testing.T) {
	srv := typesafetest.NewServer(t)
	client := srv.Client()
	call := func() *typesafe.Error {
		_, err := client.Evaluate(context.Background(), "x", readmeQuestions)
		var e *typesafe.Error
		if !errors.As(err, &e) {
			t.Fatalf("expected *Error, got %v", err)
		}
		return e
	}
	srv.StubError(401, map[string]any{"detail": map[string]any{"error_type": "authentication_error", "message": "bad key"}}, http.Header{"X-Typesafe-Request-Id": {"req_1"}})
	if e := call(); e.Type != typesafe.ErrAuth || e.Message != "bad key" || e.RequestID != "req_1" || !strings.Contains(e.Error(), "HTTP 401") {
		t.Fatalf("401: %+v", e)
	}
	srv.StubError(400, map[string]any{"detail": "Too many choices. Must have at most 255 choices."}, nil)
	if e := call(); e.Type != typesafe.ErrValidation || !strings.HasPrefix(e.Message, "Too many choices") {
		t.Fatalf("400: %+v", e)
	}
	srv.StubError(422, map[string]any{"detail": []any{map[string]any{"loc": []any{"body", "questions", "dept", "criteria"}, "msg": "Field required"}}}, nil)
	if e := call(); e.Type != typesafe.ErrValidation || e.Message != "body.questions.dept.criteria: Field required" {
		t.Fatalf("422: %+v", e)
	}
	srv.StubError(429, map[string]any{"error": "slow down"}, http.Header{"Retry-After": {"3"}})
	if e := call(); e.Type != typesafe.ErrRateLimited || e.RetryAfter != 3*time.Second || !e.Retryable() {
		t.Fatalf("429: %+v", e)
	}
	srv.StubError(529, map[string]any{"message": "overloaded"}, nil)
	if e := call(); e.Type != typesafe.ErrOverloaded || e.Message != "overloaded" {
		t.Fatalf("529: %+v", e)
	}
	srv.Handle(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(500)
		_, _ = w.Write([]byte("<html>boom</html>"))
	})
	if e := call(); e.Type != typesafe.ErrUnexpected || e.Message != "<html>boom</html>" {
		t.Fatalf("500 html: %+v", e)
	}
	srv.Handle(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("not json")) })
	if e := call(); e.Type != typesafe.ErrUnexpected || e.Status != 0 {
		t.Fatalf("bad json: %+v", e)
	}
	srv.Handle(func(w http.ResponseWriter, r *http.Request) {
		typesafetest.JSON(w, 200, map[string]any{"model": "m", "answers": map[string]any{}, "usage": map[string]any{}})
	})
	if e := call(); e.Type != typesafe.ErrUnexpected || !strings.Contains(e.Message, "missing answer") || e.Status != 200 {
		t.Fatalf("missing answer: %+v", e)
	}
}

func TestHooksReportEveryOutcome(t *testing.T) {
	var infos []typesafe.ResponseInfo
	var reqs []typesafe.RequestInfo
	hooks := typesafe.Hooks{
		OnRequest:  func(i typesafe.RequestInfo) { reqs = append(reqs, i) },
		OnResponse: func(i typesafe.ResponseInfo) { infos = append(infos, i) },
	}
	srv := typesafetest.NewServer(t)
	srv.Handle(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Typesafe-Request-Id", "req_h")
		typesafetest.JSON(w, 200, readmeResponse)
	})
	client := srv.Client(typesafe.WithHooks(hooks))
	if _, err := client.Evaluate(context.Background(), "x", readmeQuestions); err != nil {
		t.Fatal(err)
	}
	srv.StubError(529, map[string]any{}, nil)
	_, _ = client.Evaluate(context.Background(), "x", readmeQuestions)

	if len(reqs) != 2 || reqs[0].Model != "jev-latest" || reqs[0].QuestionCount != 3 || reqs[0].Path != "/v1/systemone" {
		t.Fatalf("request infos %+v", reqs)
	}
	ok, bad := infos[0], infos[1]
	if ok.Status != 200 || ok.InputTokens != 312 || ok.OutputTokens != 48 || ok.RequestID != "req_h" || ok.Err != nil || ok.RetryCount != 0 {
		t.Fatalf("ok info %+v", ok)
	}
	if bad.Status != 529 || bad.Err == nil || bad.Err.Type != typesafe.ErrOverloaded || bad.InputTokens != -1 {
		t.Fatalf("bad info %+v", bad)
	}
}

func TestEvaluateManyKeepsOrderAndCollectsErrors(t *testing.T) {
	srv := typesafetest.NewServer(t)
	srv.Handle(func(w http.ResponseWriter, r *http.Request) {
		var body struct{ State string }
		raw, _ := json.Marshal(mustBody(r))
		_ = json.Unmarshal(raw, &body)
		if body.State == "fail" {
			typesafetest.JSON(w, 500, map[string]any{"error": "boom"})
			return
		}
		var n float64
		_, _ = fmt.Sscanf(body.State, "%f", &n)
		time.Sleep(time.Duration(n) * time.Millisecond)
		typesafetest.JSON(w, 200, map[string]any{"model": "m",
			"answers": map[string]any{"q": map[string]any{"type": "noul", "noul": n / 100}},
			"usage":   map[string]any{"input_tokens": 1, "output_tokens": 1}})
	})
	client := srv.Client()
	states := []typesafe.State{"20", "fail", "5", "1", "15"}
	outcomes, err := client.EvaluateMany(context.Background(), states, typesafe.Questions{"q": typesafe.Noul("?")}, typesafe.ManyOptions{MaxConcurrency: 3})
	if err != nil {
		t.Fatal(err)
	}
	if len(outcomes) != 5 || outcomes[1].Err == nil || outcomes[1].Err.Status != 500 {
		t.Fatalf("outcomes %+v", outcomes)
	}
	for i, want := range []float64{0.2, -1, 0.05, 0.01, 0.15} {
		if want < 0 {
			continue
		}
		if outcomes[i].Result == nil || outcomes[i].Result.Noul("q").Noul != want {
			t.Fatalf("outcome %d: %+v", i, outcomes[i])
		}
	}
	if typesafe.FirstError(outcomes) != outcomes[1].Err {
		t.Fatal("FirstError")
	}
	if _, err := client.EvaluateMany(context.Background(), states, typesafe.Questions{}); err == nil {
		t.Fatal("invalid question set must fail before any request")
	}
}

func mustBody(r *http.Request) map[string]any {
	var m map[string]any
	_ = json.NewDecoder(r.Body).Decode(&m)
	return m
}

func TestModels(t *testing.T) {
	srv := typesafetest.NewServer(t)
	srv.StubModels([]typesafe.Model{
		{Name: "jev-latest", Description: "Latest", RawReleaseDate: "2026-09-10T18:38:01.391457+00:00"},
		{Name: "jev-preview", RawReleaseDate: "latest"},
	})
	models, err := srv.Client().Models(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(models) != 2 || models[0].Name != "jev-latest" || models[0].ReleaseDate.Year() != 2026 || !models[1].ReleaseDate.IsZero() || models[1].RawReleaseDate != "latest" {
		t.Fatalf("models %+v", models)
	}
	if srv.Requests()[0].Method != "GET" || srv.Requests()[0].URL.Path != "/v1/models" {
		t.Fatal("wrong endpoint")
	}
}

func TestStubsDecodeLikeRealResponses(t *testing.T) {
	srv := typesafetest.NewServer(t)
	srv.Stub(typesafetest.Answers{
		"dept": typesafetest.ChoiceOf("technical", 0.9), "urgent": typesafetest.NoulOf(0.3), "anger": typesafetest.ScoreOf(2, 0.8),
	})
	res, err := srv.Client(typesafe.WithModel("jev-x")).Evaluate(context.Background(), "hello", readmeQuestions)
	if err != nil {
		t.Fatal(err)
	}
	d, a := res.Choice("dept"), res.Score("anger")
	sum := 0.0
	for _, p := range d.Probabilities {
		sum += p
	}
	if res.Model != "jev-x" || d.Choice != "technical" || sum < 0.999 || sum > 1.001 || a.Level != 2 || a.Label != "Very angry" || a.Score < 1.69 || a.Score > 1.71 {
		t.Fatalf("stubbed result %+v %+v", d, a)
	}
}

func TestRawLayer(t *testing.T) {
	srv := typesafetest.NewServer(t)
	srv.Handle(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Typesafe-Request-Id", "req_raw")
		typesafetest.JSON(w, 200, readmeResponse)
	})
	client := srv.Client()
	body, err := client.Post(context.Background(), "/v1/systemone", map[string]any{"state": "x", "model": "jev-latest",
		"questions": map[string]any{"urgent": map[string]any{"type": "noul", "instructions": "?"}}})
	if err != nil || body["model"] != "jev-1.13.0" {
		t.Fatalf("post %v %v", body, err)
	}
	resp, err := client.Do(context.Background(), http.MethodGet, "/v1/models", nil, typesafe.CallOptions{Header: http.Header{"X-Extra": {"yes"}}})
	if err != nil || resp.RequestID != "req_raw" || resp.Status != 200 {
		t.Fatalf("do %+v %v", resp, err)
	}
	if srv.Requests()[1].Header.Get("X-Extra") != "yes" {
		t.Fatal("extra header not sent")
	}
}

func TestLive(t *testing.T) {
	key := os.Getenv(typesafe.EnvAPIKey)
	if os.Getenv("TYPESAFE_LIVE_TESTS") != "1" || key == "" {
		t.Skip("set TYPESAFE_API_KEY and TYPESAFE_LIVE_TESTS=1 to run live tests")
	}
	client, err := typesafe.New()
	if err != nil {
		t.Fatal(err)
	}
	res, err := client.Evaluate(context.Background(), "Help! My payouts have been failing for 3 days.", readmeQuestions)
	if err != nil {
		t.Fatal(err)
	}
	if res.RequestID == "" || res.Noul("urgent") == nil || res.Choice("dept") == nil || res.Score("anger") == nil {
		t.Fatalf("live result %+v", res)
	}
	models, err := client.Models(context.Background())
	if err != nil || len(models) == 0 {
		t.Fatalf("models %v %v", models, err)
	}
}
