# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0-alpha.1] - 2026-09-17

### Added

- `TypeSafe.new/1` client struct resolving configuration from options, application
  config, and `TYPESAFE_*` environment variables.
- `TypeSafe.evaluate/4` and `evaluate!/4` with typed `Noul`, `Choice`, and `Score`
  questions and answers; caller keys (atoms or strings) round-trip without
  `String.to_atom/1`.
- `TypeSafe.evaluate_many/4` concurrent fan-out with ordered results and `on_error` modes.
- `TypeSafe.models/1` for `GET /v1/models`.
- `TypeSafe.Retry` mirroring the official SDK policy, including `retry-after-ms`,
  `Retry-After` (seconds or HTTP date), and a total time budget per call.
- `TypeSafe.HTTP` raw layer (maps in, maps out) built on Req with the built-in `JSON` module.
- `TypeSafe.Error` typed error values: `:auth`, `:validation`, `:rate_limited`,
  `:overloaded`, `:timeout`, `:connection`, `:unexpected`.
- Telemetry spans `[:typesafe, :request, *]` and `TypeSafe.Telemetry.attach_logger/1`.
- `TypeSafe.Test` stubs by question id for downstream test suites.
- `TypeSafe.Answer.gate/2` and `yes?/2` helpers for confidence-gated routing.
- `TypeSafe.FanOut.options_schema/0`; `TypeSafe.evaluate/4` and `evaluate_many/4` render
  their full option tables inline in the docs.
- `TypeSafe.Result.request_id` and `TypeSafe.HTTP.request/5` returning a
  `TypeSafe.HTTP.Response` with status, headers, `request_id`, and retry count.
- Local validation that a Choice has 2 to 255 options (the API's ceiling is 255).
- `TypeSafe.Model.release_date` parsed as a `DateTime` when the API sends one.
- HTTP 400 responses map to `type: :validation`; error messages are read from the
  API's `detail.message` shape as well as string and list details.
- `TypeSafe.Answer.Score.description` carrying the winning level as written; `label` is
  always a string.
- `TypeSafe.Question.validate!/1` for eager, raising validation of questions built at
  compile time; constructors themselves never validate.
- `TypeSafe.SystemOne.prepare/1` returning a `TypeSafe.SystemOne.Prepared` struct for
  reuse across many states.
- `livebooks/live_walkthrough.livemd`, a Livebook notebook that runs the README example
  against the live API and shows the request, raw response, and typed result.

[Unreleased]: https://github.com/typesend/typesafe_ai/compare/v0.1.0-alpha.1...HEAD
[0.1.0-alpha.1]: https://github.com/typesend/typesafe_ai/releases/tag/v0.1.0-alpha.1
