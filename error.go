package typesafe

import (
	"fmt"
	"time"
)

// ErrorType classifies a failed call so callers can branch without parsing
// messages.
type ErrorType string

const (
	// ErrAuth is HTTP 401: the API key is missing or invalid.
	ErrAuth ErrorType = "auth"
	// ErrValidation is HTTP 400 or 422, or a problem caught locally before
	// any request was sent. Status is 0 for local validation errors.
	ErrValidation ErrorType = "validation"
	// ErrRateLimited is HTTP 429 after retries are exhausted.
	ErrRateLimited ErrorType = "rate_limited"
	// ErrOverloaded is HTTP 529 or 503 after retries are exhausted.
	ErrOverloaded ErrorType = "overloaded"
	// ErrTimeout means a request exceeded its timeout without a response.
	ErrTimeout ErrorType = "timeout"
	// ErrConnection means the server could not be reached.
	ErrConnection ErrorType = "connection"
	// ErrUnexpected covers unknown statuses, undecodable bodies, and
	// response shapes this package does not understand.
	ErrUnexpected ErrorType = "unexpected"
)

// Error is the single error type returned by every failed call. Use
// errors.As to reach it.
type Error struct {
	Type    ErrorType
	Status  int    // HTTP status, or 0 when no response was involved
	Message string // one-line summary; 422 details are joined as "loc.path: msg; ..."
	// Body is the decoded JSON error body (map[string]any), the raw string
	// when the body was not JSON, or nil. For an ErrUnexpected raised while
	// decoding a 2xx response, Body is the offending part of that response
	// and Status is the 2xx status the server sent.
	Body any
	// RequestID is the x-typesafe-request-id response header. Quote it when
	// contacting TypeSafe support.
	RequestID string
	// RetryAfter is the wait the server asked for via retry-after-ms or
	// Retry-After, kept even after retries are exhausted; zero if absent.
	RetryAfter time.Duration
	// Err is the underlying transport error, if any.
	Err error
}

// Error formats the error as "typesafe: <type> (HTTP <status>): <message>",
// omitting the status for local errors.
func (e *Error) Error() string {
	if e.Status == 0 {
		return fmt.Sprintf("typesafe: %s: %s", e.Type, e.Message)
	}
	return fmt.Sprintf("typesafe: %s (HTTP %d): %s", e.Type, e.Status, e.Message)
}

// Unwrap exposes the transport error for errors.Is checks such as
// context.DeadlineExceeded.
func (e *Error) Unwrap() error { return e.Err }

// Retryable reports whether the error type is one the retry policy would
// have retried: rate limits, overloads, timeouts, and connection failures.
func (e *Error) Retryable() bool {
	switch e.Type {
	case ErrRateLimited, ErrOverloaded, ErrTimeout, ErrConnection:
		return true
	}
	return false
}

func validationError(format string, args ...any) *Error {
	return &Error{Type: ErrValidation, Message: fmt.Sprintf(format, args...)}
}

func unexpectedError(body any, format string, args ...any) *Error {
	return &Error{Type: ErrUnexpected, Message: fmt.Sprintf(format, args...), Body: body}
}

func typeForStatus(status int) ErrorType {
	switch status {
	case 401:
		return ErrAuth
	case 400, 422:
		return ErrValidation
	case 429:
		return ErrRateLimited
	case 503, 529:
		return ErrOverloaded
	}
	return ErrUnexpected
}

func defaultMessage(status int) string {
	switch status {
	case 400:
		return "The request was rejected"
	case 401:
		return "Missing or invalid API key"
	case 422:
		return "The request body failed validation"
	case 429:
		return "Rate limit exceeded"
	case 529:
		return "TypeSafe is temporarily overloaded"
	}
	return fmt.Sprintf("Unexpected HTTP status %d", status)
}

// extractMessage mirrors the official SDKs: prefer "error", then "message",
// then "detail" (a string, a {message} object, or a list of {loc, msg}).
func extractMessage(body any) string {
	switch b := body.(type) {
	case string:
		return b
	case map[string]any:
		if s, ok := b["error"].(string); ok && s != "" {
			return s
		}
		if m, ok := b["error"].(map[string]any); ok {
			if s, ok := m["message"].(string); ok && s != "" {
				return s
			}
		}
		if s, ok := b["message"].(string); ok && s != "" {
			return s
		}
		switch d := b["detail"].(type) {
		case string:
			return d
		case map[string]any:
			if s, ok := d["message"].(string); ok {
				return s
			}
		case []any:
			return joinDetails(d)
		}
	}
	return ""
}

func joinDetails(details []any) string {
	out := ""
	for _, d := range details {
		m, ok := d.(map[string]any)
		if !ok {
			continue
		}
		msg, _ := m["msg"].(string)
		if msg == "" {
			continue
		}
		line := msg
		if loc, ok := m["loc"].([]any); ok && len(loc) > 0 {
			path := ""
			for i, part := range loc {
				if i > 0 {
					path += "."
				}
				path += fmt.Sprint(part)
			}
			line = path + ": " + msg
		}
		if out != "" {
			out += "; "
		}
		out += line
	}
	return out
}
