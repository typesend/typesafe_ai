# Changelog

All notable changes to the Go client are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0-alpha.1] - 2026-09-17

### Added

- `typesafe.New` with functional options, resolving configuration from options then
  `TYPESAFE_*` environment variables.
- `Client.Evaluate`, `EvaluatePrepared`, and `EvaluateMany` with typed `Noul`, `Choice`,
  and `Score` questions and answers; Choice options keep caller order on the wire.
- `Client.Models` for `GET /v1/models`.
- `RetryPolicy` mirroring the official SDKs, including `retry-after-ms`, `Retry-After`
  (seconds or HTTP date), and a total time budget per call.
- Raw layer: `Client.Post`, `Client.Get`, and `Client.Do` returning a `Response` with
  headers and `RequestID`.
- `*typesafe.Error` with a `Type` for `auth`, `validation`, `rate_limited`, `overloaded`,
  `timeout`, `connection`, and `unexpected`, plus `Body`, `RequestID`, and `RetryAfter`.
- `Hooks` for per-request telemetry.
- `typesafetest` stub server building wire-accurate responses by question id.
- `Gate`, `NoulAnswer.Yes`, and `ScoreAnswer.Normalized` helpers.
- Reliability: per-state timeouts and panic isolation in `EvaluateMany`, context-aware
  retry sleeps, a tuned `DefaultTransport` for fan-out, hook panic recovery, and
  `WithMaxResponseBytes`.

[Unreleased]: https://github.com/typesend/typesafe_ai/compare/go/v0.1.0-alpha.1...go-sdk
[0.1.0-alpha.1]: https://github.com/typesend/typesafe_ai/releases/tag/go/v0.1.0-alpha.1
