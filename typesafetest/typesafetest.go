// Package typesafetest stubs the TypeSafe API for tests: no fixtures, no
// network. Describe the answer you want per question id and the server
// builds a wire-accurate response, so the decoded structs are identical to
// those from a real call.
//
//	srv := typesafetest.NewServer(t)
//	srv.Stub(typesafetest.Answers{
//		"dept":   typesafetest.ChoiceOf("billing", 0.9),
//		"urgent": typesafetest.NoulOf(0.3),
//		"anger":  typesafetest.ScoreOf(1, 0.8),
//	})
//	client := srv.Client()
//
// A request for a question that has no stub fails the test with a clear
// message, so a test cannot silently pass on a default answer.
package typesafetest

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sort"
	"strconv"
	"sync"
	"testing"

	typesafe "github.com/typesend/typesafe_ai"
)

// AnswerSpec describes how to answer one question.
type AnswerSpec struct {
	kind       string
	noul       float64
	choice     string
	level      int
	confidence float64
}

// NoulOf answers a Noul question with the given probability.
func NoulOf(probability float64) AnswerSpec { return AnswerSpec{kind: "noul", noul: probability} }

// ChoiceOf answers a Choice question with option and confidence; the
// remaining probability is spread evenly over the other options.
func ChoiceOf(option string, confidence float64) AnswerSpec {
	return AnswerSpec{kind: "choice", choice: option, confidence: confidence}
}

// ScoreOf answers a Score question with a 0-based level and confidence; the
// remaining probability is spread evenly over the other levels.
func ScoreOf(level int, confidence float64) AnswerSpec {
	return AnswerSpec{kind: "score", level: level, confidence: confidence}
}

// Answers maps question ids to answer specs.
type Answers map[string]AnswerSpec

// Server is a stub TypeSafe API backed by httptest.Server.
type Server struct {
	t        testing.TB
	srv      *httptest.Server
	mu       sync.Mutex
	handler  http.HandlerFunc
	requests []*http.Request
	bodies   [][]byte
}

// NewServer starts a stub server that is closed when the test ends. Until a
// stub is set, every request fails the test.
func NewServer(t testing.TB) *Server {
	t.Helper()
	s := &Server{t: t}
	s.srv = httptest.NewServer(http.HandlerFunc(s.serve))
	t.Cleanup(s.srv.Close)
	return s
}

// URL is the base URL to point a client at.
func (s *Server) URL() string { return s.srv.URL }

// Client builds a typesafe.Client pointed at the server with retries
// disabled. Extra options are applied after, so they can re-enable retries.
func (s *Server) Client(opts ...typesafe.Option) *typesafe.Client {
	s.t.Helper()
	all := append([]typesafe.Option{
		typesafe.WithAPIKey("test-key"),
		typesafe.WithBaseURL(s.srv.URL),
		typesafe.WithRetry(typesafe.NoRetry()),
	}, opts...)
	c, err := typesafe.New(all...)
	if err != nil {
		s.t.Fatalf("typesafetest: building client: %v", err)
	}
	return c
}

// Requests returns every request received so far, oldest first, with
// Bodies holding the raw request bodies in the same order.
func (s *Server) Requests() []*http.Request {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]*http.Request(nil), s.requests...)
}

// Bodies returns the raw request bodies received so far.
func (s *Server) Bodies() [][]byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([][]byte(nil), s.bodies...)
}

// Handle replaces the stub with a custom handler for cases the built-in
// stubs do not cover.
func (s *Server) Handle(h http.HandlerFunc) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.handler = h
}

// Stub answers evaluation requests using the given specs.
func (s *Server) Stub(answers Answers) {
	s.Handle(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req struct {
			Model     string                    `json:"model"`
			Questions map[string]map[string]any `json:"questions"`
		}
		if err := json.Unmarshal(body, &req); err != nil || req.Questions == nil {
			JSON(w, 422, map[string]any{"detail": "typesafetest: request body is not a systemone request"})
			return
		}
		out := map[string]any{}
		for id, q := range req.Questions {
			a, err := s.answer(id, q, answers)
			if err != nil {
				s.t.Errorf("typesafetest: %v", err)
				JSON(w, 500, map[string]any{"error": err.Error()})
				return
			}
			out[id] = a
		}
		JSON(w, 200, map[string]any{
			"model":   req.Model,
			"answers": out,
			"usage":   map[string]any{"input_tokens": len(body) / 4, "output_tokens": len(out) * 8},
		})
	})
}

// StubError answers every request with an HTTP error.
func (s *Server) StubError(status int, body any, header http.Header) {
	s.Handle(func(w http.ResponseWriter, r *http.Request) {
		for k, vs := range header {
			for _, v := range vs {
				w.Header().Add(k, v)
			}
		}
		JSON(w, status, body)
	})
}

// StubModels answers the models endpoint.
func (s *Server) StubModels(models []typesafe.Model) {
	s.Handle(func(w http.ResponseWriter, r *http.Request) {
		out := make([]map[string]any, len(models))
		for i, m := range models {
			date := m.RawReleaseDate
			if date == "" && !m.ReleaseDate.IsZero() {
				date = m.ReleaseDate.UTC().Format("2006-01-02T15:04:05.000000Z07:00")
			}
			out[i] = map[string]any{"name": m.Name, "description": m.Description, "release_date": date}
		}
		JSON(w, 200, map[string]any{"models": out})
	})
}

// JSON writes a JSON response, for custom handlers.
func JSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func (s *Server) serve(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	r.Body = io.NopCloser(bytesReader(body))
	s.mu.Lock()
	s.requests = append(s.requests, r)
	s.bodies = append(s.bodies, body)
	h := s.handler
	s.mu.Unlock()
	if h == nil {
		s.t.Errorf("typesafetest: request to %s %s with no stub set", r.Method, r.URL.Path)
		JSON(w, 500, map[string]any{"error": "no stub"})
		return
	}
	h(w, r)
}

func (s *Server) answer(id string, q map[string]any, specs Answers) (map[string]any, error) {
	typ, _ := q["type"].(string)
	spec, ok := specs[id]
	if !ok {
		return nil, fmt.Errorf("no stub for question %q (a %s question)", id, typ)
	}
	if spec.kind != typ {
		return nil, fmt.Errorf("stub for %q is a %s answer but the question is a %s", id, spec.kind, typ)
	}
	switch typ {
	case "noul":
		return map[string]any{"type": "noul", "noul": spec.noul}, nil
	case "choice":
		criteria, _ := q["criteria"].(map[string]any)
		keys := make([]string, 0, len(criteria))
		for k := range criteria {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		if _, ok := criteria[spec.choice]; !ok {
			return nil, fmt.Errorf("question %q has no option %q; options are %v", id, spec.choice, keys)
		}
		return map[string]any{
			"type": "choice", "choice": spec.choice,
			"probabilities": spread(keys, spec.choice, spec.confidence),
			"confidence":    spec.confidence,
		}, nil
	case "score":
		levels, _ := q["criteria"].([]any)
		if spec.level < 0 || spec.level >= len(levels) {
			return nil, fmt.Errorf("question %q has %d levels; got level %d", id, len(levels), spec.level)
		}
		keys := make([]string, len(levels))
		legend := map[string]any{}
		for i, l := range levels {
			keys[i] = strconv.Itoa(i)
			legend[keys[i]] = l
		}
		probs := spread(keys, strconv.Itoa(spec.level), spec.confidence)
		score := 0.0
		for k, p := range probs {
			i, _ := strconv.Atoi(k)
			score += float64(i) * p
		}
		return map[string]any{
			"type": "score", "score": score, "legend": legend,
			"probabilities": probs, "confidence": spec.confidence,
		}, nil
	}
	return nil, fmt.Errorf("question %q has unknown type %q", id, typ)
}

func spread(keys []string, chosen string, confidence float64) map[string]float64 {
	out := make(map[string]float64, len(keys))
	if len(keys) == 1 {
		out[chosen] = 1
		return out
	}
	each := (1 - confidence) / float64(len(keys)-1)
	for _, k := range keys {
		if k == chosen {
			out[k] = confidence
		} else {
			out[k] = each
		}
	}
	return out
}
