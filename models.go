package typesafe

import (
	"context"
	"time"
)

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
	body, err := c.Get(ctx, ModelsPath, opts...)
	if err != nil {
		return nil, err
	}
	raw, ok := body["models"].([]any)
	if !ok {
		return nil, unexpectedError(body, `expected a "models" array in the response`)
	}
	models := make([]Model, 0, len(raw))
	for _, entry := range raw {
		m, ok := entry.(map[string]any)
		name, okn := m["name"].(string)
		if !ok || !okn {
			return nil, unexpectedError(body, "malformed model entry: %v", entry)
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
