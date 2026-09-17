package typesafe

import (
	"context"
	"net/http"
	"time"
)

// decodeError stamps a decode-shape error with the status and request id of
// the 2xx response it came from.
func decodeError(resp *Response, e *Error) *Error {
	e.Status = resp.Status
	e.RequestID = resp.RequestID
	return e
}

// ModelsPath is the models endpoint. It is not on the public API reference;
// the path and shape come from the official Python SDK.
const ModelsPath = "/v1/models"

// Model describes a model available to the account.
type Model struct {
	Name        string
	Description string
	// ReleaseDate is parsed from the API's ISO 8601 value when possible;
	// RawReleaseDate keeps the original string either way.
	ReleaseDate    time.Time
	RawReleaseDate string
}

// Models lists the models available to the account, for example jev-latest
// and jev-preview.
func (c *Client) Models(ctx context.Context, opts ...CallOptions) ([]Model, error) {
	resp, err := c.Do(ctx, http.MethodGet, ModelsPath, nil, opts...)
	if err != nil {
		return nil, err
	}
	body := resp.Body
	raw, ok := body["models"].([]any)
	if !ok {
		return nil, decodeError(resp, unexpectedError(body, `expected a "models" array in the response`))
	}
	models := make([]Model, 0, len(raw))
	for _, entry := range raw {
		m, ok := entry.(map[string]any)
		name, okn := m["name"].(string)
		if !ok || !okn {
			return nil, decodeError(resp, unexpectedError(body, "malformed model entry: %v", entry))
		}
		model := Model{Name: name}
		model.Description, _ = m["description"].(string)
		if s, ok := m["release_date"].(string); ok {
			model.RawReleaseDate = s
			for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02"} {
				if t, err := time.Parse(layout, s); err == nil {
					model.ReleaseDate = t
					break
				}
			}
		}
		models = append(models, model)
	}
	return models, nil
}
