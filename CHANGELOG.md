# Changelog

All notable changes to this project are documented here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `PhoenixAnalytics.Plug`, recording server-side pageviews into
  [Seriously Simple Analytics](https://seriouslysimpleanalytics.com).
- A shared session with the browser tag: both halves read the same `wa_sid`
  cookie and choose the same pageview number, so one visit stays one visit and
  server-side and browser-side data merge into a single row.
- Capture of traffic that runs no JavaScript — AI agents, crawlers, scripts and
  API clients — which a browser tag cannot observe at all.
- Forwarding of the visitor's address and CDN geolocation headers, so a beacon
  posted by the server still resolves to the visitor's location.
- Asynchronous, bounded delivery: a request never waits on a beacon, and a slow
  or failing collector is dropped rather than allowed to grow without limit.
