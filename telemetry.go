package typesafe

import "time"

// Hooks receive one callback per request, after retries are exhausted or
// the call succeeded. Failures of every kind (auth, rate limit, timeout,
// connection, unexpected) arrive through the same hook with Err set; there
// is no separate exception path.
//
// Hooks run synchronously on the calling goroutine; keep them fast.
//
//	hooks := typesafe.Hooks{OnResponse: func(i typesafe.ResponseInfo) {
//		if i.Err != nil {
//			log.Printf("typesafe %s %s: %v", i.Method, i.Path, i.Err)
//		}
//		if i.InputTokens >= 0 {
//			tokens.Add(float64(i.InputTokens + i.OutputTokens))
//		}
//		latency.Observe(i.Duration.Seconds())
//	}}
type Hooks struct {
	// OnRequest is called before the first attempt.
	OnRequest func(RequestInfo)
	// OnResponse is called once per call, after the final attempt.
	OnResponse func(ResponseInfo)
}

// RequestInfo describes a request about to be sent.
type RequestInfo struct {
	Method        string
	Path          string
	Model         string // "" for requests without a body
	QuestionCount int    // 0 for requests without questions
}

// ResponseInfo describes how a call ended.
type ResponseInfo struct {
	RequestInfo
	Status       int // 0 when no response arrived
	Duration     time.Duration
	RetryCount   int
	InputTokens  int // -1 when the response carried no usage
	OutputTokens int
	RequestID    string
	Err          *Error // nil on success
}

func (h Hooks) request(info RequestInfo) {
	if h.OnRequest != nil {
		h.OnRequest(info)
	}
}

func (h Hooks) response(info ResponseInfo) {
	if h.OnResponse != nil {
		h.OnResponse(info)
	}
}
