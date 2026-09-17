package typesafe

import (
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

// Environment variable names, shared with the official SDKs.
const (
	EnvAPIKey       = "TYPESAFE_API_KEY"
	EnvBaseURL      = "TYPESAFE_BASE_URL"
	EnvDefaultModel = "TYPESAFE_DEFAULT_MODEL"
)

// Defaults, shared with the official SDKs.
const (
	DefaultBaseURL = "https://api.typesafe.ai"
	DefaultModel   = "jev-latest"
	DefaultTimeout = 10 * time.Second
)

// Client holds connection settings. It is immutable after New, cheap to
// copy, and safe to share across goroutines: build one and pass it around.
//
// The API key is never included in String, telemetry hooks, or errors.
type Client struct {
	apiKey     string
	baseURL    string
	model      string
	timeout    time.Duration
	retry      RetryPolicy
	httpClient *http.Client
	hooks      Hooks
	maxBody    int64
}

// DefaultMaxResponseBytes bounds how much of a response body is read.
const DefaultMaxResponseBytes = 16 << 20

// Option configures a Client.
type Option func(*Client)

// WithAPIKey sets the API key. Falls back to TYPESAFE_API_KEY.
func WithAPIKey(key string) Option { return func(c *Client) { c.apiKey = key } }

// WithBaseURL sets the API base URL. Falls back to TYPESAFE_BASE_URL, then
// DefaultBaseURL.
func WithBaseURL(u string) Option { return func(c *Client) { c.baseURL = u } }

// WithModel sets the default model. Falls back to TYPESAFE_DEFAULT_MODEL,
// then DefaultModel. jev-latest resolves to a versioned id such as
// jev-1.13.0, which is what Result.Model reports.
func WithModel(m string) Option { return func(c *Client) { c.model = m } }

// WithTimeout sets the per-attempt timeout. Default 10s. Each retry gets its
// own attempt timeout; the retry policy's Budget bounds the whole call.
func WithTimeout(d time.Duration) Option { return func(c *Client) { c.timeout = d } }

// WithRetry sets the retry policy. Default DefaultRetryPolicy.
func WithRetry(p RetryPolicy) Option { return func(c *Client) { c.retry = p } }

// WithHTTPClient sets the underlying http.Client, for proxies, custom
// transports, or connection pool tuning. Its Timeout field is ignored; use
// WithTimeout.
func WithHTTPClient(h *http.Client) Option { return func(c *Client) { c.httpClient = h } }

// WithHooks sets telemetry hooks called around every request.
func WithHooks(h Hooks) Option { return func(c *Client) { c.hooks = h } }

// WithMaxResponseBytes caps the bytes read from any response body, so a
// misbehaving server cannot exhaust memory. Default DefaultMaxResponseBytes.
func WithMaxResponseBytes(n int64) Option { return func(c *Client) { c.maxBody = n } }

// DefaultTransport returns the http.Transport New uses when no http.Client
// is supplied. It differs from http.DefaultTransport in keeping enough idle
// connections per host for concurrent fan-out (EvaluateMany) instead of the
// standard library's two, which would otherwise open and close a connection
// for most requests under load.
func DefaultTransport() *http.Transport {
	return &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          256,
		MaxIdleConnsPerHost:   64,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: time.Second,
	}
}

// New builds a Client. Settings resolve from options, then TYPESAFE_*
// environment variables, then defaults. It returns a *Error of type
// ErrValidation when no API key is found or an option is invalid.
func New(opts ...Option) (*Client, error) {
	c := &Client{retry: DefaultRetryPolicy()}
	for _, opt := range opts {
		opt(c)
	}
	if c.apiKey == "" {
		c.apiKey = strings.TrimSpace(os.Getenv(EnvAPIKey))
	}
	if c.apiKey == "" {
		return nil, validationError("no API key found: pass typesafe.WithAPIKey or set %s", EnvAPIKey)
	}
	if c.baseURL == "" {
		c.baseURL = strings.TrimSpace(os.Getenv(EnvBaseURL))
	}
	if c.baseURL == "" {
		c.baseURL = DefaultBaseURL
	}
	c.baseURL = strings.TrimRight(c.baseURL, "/")
	if c.model == "" {
		c.model = strings.TrimSpace(os.Getenv(EnvDefaultModel))
	}
	if c.model == "" {
		c.model = DefaultModel
	}
	if c.timeout == 0 {
		c.timeout = DefaultTimeout
	}
	if c.timeout < 0 {
		return nil, validationError("timeout must be positive, got %v", c.timeout)
	}
	if err := c.retry.validate(); err != nil {
		return nil, err
	}
	if c.httpClient == nil {
		c.httpClient = &http.Client{Transport: DefaultTransport()}
	}
	if c.maxBody == 0 {
		c.maxBody = DefaultMaxResponseBytes
	}
	if c.maxBody < 0 {
		return nil, validationError("max response bytes must be positive, got %d", c.maxBody)
	}
	return c, nil
}

// Model returns the default model.
func (c *Client) Model() string { return c.model }

// BaseURL returns the resolved base URL.
func (c *Client) BaseURL() string { return c.baseURL }

// Timeout returns the per-attempt timeout.
func (c *Client) Timeout() time.Duration { return c.timeout }

// Retry returns the retry policy.
func (c *Client) Retry() RetryPolicy { return c.retry }

// String redacts the API key.
func (c *Client) String() string {
	return "typesafe.Client{baseURL: " + c.baseURL + ", model: " + c.model + ", apiKey: [REDACTED]}"
}

// GoString redacts the API key from %#v as well.
func (c *Client) GoString() string { return c.String() }
