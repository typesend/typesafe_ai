package typesafe

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"time"
)

// Response is a successful raw response: the decoded JSON body plus the
// metadata support conversations need.
type Response struct {
	Status     int
	Body       map[string]any
	Header     http.Header
	RequestID  string // the x-typesafe-request-id header
	RetryCount int
}

// CallOptions adjust one call. The zero value uses the client's settings.
type CallOptions struct {
	// Model overrides the client's default model for this call.
	Model string
	// Timeout overrides the per-attempt timeout.
	Timeout time.Duration
	// Retry overrides the retry policy.
	Retry *RetryPolicy
	// Header adds request headers. Authorization, Content-Type, Accept and
	// User-Agent cannot be overridden.
	Header http.Header
}

// Post sends a JSON POST through the raw layer and returns the decoded
// body. Same auth, retries, and hooks as the typed layer; no structs.
func (c *Client) Post(ctx context.Context, path string, body any, opts ...CallOptions) (map[string]any, error) {
	resp, err := c.Do(ctx, http.MethodPost, path, body, opts...)
	if err != nil {
		return nil, err
	}
	return resp.Body, nil
}

// Get sends a GET through the raw layer and returns the decoded body.
func (c *Client) Get(ctx context.Context, path string, opts ...CallOptions) (map[string]any, error) {
	resp, err := c.Do(ctx, http.MethodGet, path, nil, opts...)
	if err != nil {
		return nil, err
	}
	return resp.Body, nil
}

// Do sends a request and returns the full Response. body is JSON-encoded
// when non-nil. Errors are always *Error.
func (c *Client) Do(ctx context.Context, method, path string, body any, opts ...CallOptions) (*Response, error) {
	var opt CallOptions
	if len(opts) > 0 {
		opt = opts[0]
	}
	timeout := c.timeout
	if opt.Timeout > 0 {
		timeout = opt.Timeout
	}
	policy := c.retry
	if opt.Retry != nil {
		policy = *opt.Retry
		if err := policy.validate(); err != nil {
			return nil, err
		}
	}

	var payload []byte
	info := RequestInfo{Method: method, Path: path}
	if body != nil {
		var err error
		payload, err = json.Marshal(body)
		if err != nil {
			return nil, validationError("request body is not JSON-encodable: %v", err)
		}
		describeBody(body, &info)
	}
	c.hooks.request(info)

	start := policy.nowFn()()
	resp, err := c.attemptLoop(ctx, method, path, payload, timeout, policy, opt.Header, start)

	rinfo := ResponseInfo{RequestInfo: info, Duration: policy.nowFn()().Sub(start), InputTokens: -1, OutputTokens: -1}
	if resp != nil {
		rinfo.Status = resp.Status
		rinfo.RetryCount = resp.RetryCount
		rinfo.RequestID = resp.RequestID
		if usage, ok := resp.Body["usage"].(map[string]any); ok {
			rinfo.InputTokens = intField(usage, "input_tokens")
			rinfo.OutputTokens = intField(usage, "output_tokens")
		}
	}
	if err != nil {
		var e *Error
		if errors.As(err, &e) {
			rinfo.Err = e
			rinfo.Status = e.Status
			rinfo.RequestID = e.RequestID
		}
	}
	c.hooks.response(rinfo)
	return resp, err
}

func (c *Client) attemptLoop(ctx context.Context, method, path string, payload []byte, timeout time.Duration, policy RetryPolicy, extra http.Header, start time.Time) (*Response, error) {
	retries := 0
	for {
		resp, httpResp, err := c.attempt(ctx, method, path, payload, timeout, extra, retries)
		if err == nil {
			resp.RetryCount = retries
			return resp, nil
		}
		if ctx.Err() != nil {
			return nil, err // the caller's context ended; never retry past it
		}
		if retries >= policy.MaxRetries || !retryable(policy, httpResp, err) {
			return nil, err
		}
		attempt := retries + 1
		delay := policy.delay(httpResp, attempt)
		if policy.Budget > 0 {
			elapsed := policy.nowFn()().Sub(start)
			if elapsed+delay >= policy.Budget {
				return nil, err
			}
		}
		if err := sleepCtx(ctx, policy, delay); err != nil {
			return nil, err // cancelled while waiting to retry
		}
		retries = attempt
	}
}

// sleepCtx waits for delay or until ctx ends, whichever comes first. The
// policy's injected sleep (tests) is used verbatim when set.
func sleepCtx(ctx context.Context, p RetryPolicy, delay time.Duration) error {
	if p.sleep != nil {
		p.sleep(delay)
		return nil
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return &Error{Type: ErrConnection, Message: "cancelled while waiting to retry: " + ctx.Err().Error(), Err: ctx.Err()}
	}
}

func retryable(p RetryPolicy, httpResp *http.Response, err error) bool {
	if httpResp != nil {
		return p.retryableStatus(httpResp.StatusCode)
	}
	var e *Error
	if !errors.As(err, &e) {
		return false
	}
	switch e.Type {
	case ErrTimeout:
		return p.RetryTimeoutErrors
	case ErrConnection:
		return p.RetryConnectionErrors
	}
	return false
}

// attempt performs one HTTP round trip. The returned *http.Response is set
// (with its body already consumed) for non-2xx statuses so the retry loop
// can read headers; it is nil for transport failures.
func (c *Client) attempt(ctx context.Context, method, path string, payload []byte, timeout time.Duration, extra http.Header, retryCount int) (*Response, *http.Response, error) {
	actx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	var reader io.Reader
	if payload != nil {
		reader = bytes.NewReader(payload)
	}
	req, err := http.NewRequestWithContext(actx, method, c.baseURL+path, reader)
	if err != nil {
		return nil, nil, validationError("invalid request: %v", err)
	}
	for k, vs := range extra {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	req.Header.Set("Authorization", "Bearer "+c.apiKey)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", userAgent)
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if retryCount > 0 {
		req.Header.Set("X-TypeSafe-Retry-Count", strconv.Itoa(retryCount))
	}

	httpResp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, nil, transportError(err, ctx)
	}
	defer func() { _ = httpResp.Body.Close() }()
	raw, err := io.ReadAll(io.LimitReader(httpResp.Body, c.maxBody+1))
	if err != nil {
		return nil, nil, transportError(err, ctx)
	}
	if int64(len(raw)) > c.maxBody {
		return nil, nil, &Error{Type: ErrUnexpected, Status: httpResp.StatusCode,
			Message:   fmt.Sprintf("response body exceeds %d bytes", c.maxBody),
			RequestID: httpResp.Header.Get("x-typesafe-request-id")}
	}

	requestID := httpResp.Header.Get("x-typesafe-request-id")
	decoded, decodeErr := decodeBody(raw)

	if httpResp.StatusCode >= 200 && httpResp.StatusCode <= 299 {
		obj, ok := decoded.(map[string]any)
		if decodeErr != nil {
			return nil, httpResp, &Error{Type: ErrUnexpected, Message: "response body is not valid JSON", Body: string(raw), RequestID: requestID}
		}
		if !ok {
			return nil, httpResp, &Error{Type: ErrUnexpected, Message: "expected a JSON object body", Body: decoded, RequestID: requestID}
		}
		return &Response{Status: httpResp.StatusCode, Body: obj, Header: httpResp.Header, RequestID: requestID}, httpResp, nil
	}

	errBody := decoded
	if decodeErr != nil {
		errBody = string(raw)
	}
	msg := extractMessage(errBody)
	if msg == "" {
		msg = defaultMessage(httpResp.StatusCode)
	}
	e := &Error{
		Type:      typeForStatus(httpResp.StatusCode),
		Status:    httpResp.StatusCode,
		Message:   msg,
		Body:      errBody,
		RequestID: requestID,
	}
	if d, ok := RetryAfter(httpResp.Header); ok {
		e.RetryAfter = d
	}
	return nil, httpResp, e
}

func transportError(err error, ctx context.Context) *Error {
	var netErr net.Error
	timeout := errors.Is(err, context.DeadlineExceeded) ||
		errors.Is(err, os.ErrDeadlineExceeded) ||
		(errors.As(err, &netErr) && netErr.Timeout())
	if ctx.Err() != nil {
		// The caller's own context ended; report it as it happened.
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			timeout = true
		} else {
			return &Error{Type: ErrConnection, Message: "request cancelled: " + err.Error(), Err: err}
		}
	}
	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		err = urlErr.Err
	}
	if timeout {
		return &Error{Type: ErrTimeout, Message: "request timed out: " + err.Error(), Err: err}
	}
	return &Error{Type: ErrConnection, Message: "connection error: " + err.Error(), Err: err}
}

func decodeBody(raw []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	return normalizeNumbers(v), nil
}

// normalizeNumbers turns json.Number into int (when integral) or float64,
// so callers see ordinary Go numbers while integer token counts stay exact.
func normalizeNumbers(v any) any {
	switch t := v.(type) {
	case json.Number:
		if i, err := t.Int64(); err == nil {
			return int(i)
		}
		f, _ := t.Float64()
		return f
	case map[string]any:
		for k, val := range t {
			t[k] = normalizeNumbers(val)
		}
		return t
	case []any:
		for i, val := range t {
			t[i] = normalizeNumbers(val)
		}
		return t
	}
	return v
}

func describeBody(body any, info *RequestInfo) {
	m, ok := body.(map[string]any)
	if !ok {
		return
	}
	if s, ok := m["model"].(string); ok {
		info.Model = s
	}
	switch q := m["questions"].(type) {
	case map[string]any:
		info.QuestionCount = len(q)
	case Questions:
		info.QuestionCount = len(q)
	}
}

func intField(m map[string]any, key string) int {
	switch v := m[key].(type) {
	case int:
		return v
	case float64:
		return int(v)
	}
	return -1
}
