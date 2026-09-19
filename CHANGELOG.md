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
- `PhoenixAnalytics.MCP.Plug`, which serves the host application as an MCP
  server and records every call against the same analytics session as that
  agent's page reads. Four built-in tools answerable with no configuration —
  `list_pages`, `read_page`, `site_activity`, `record_event` — plus a behaviour
  for an application's own. Speaks the stateless 2026-07-28 revision and the
  handshake era from 2024-11-05 through 2025-11-25.
- `mix phoenix_analytics.server_json`, which writes the descriptor an MCP
  registry needs to list a mounted site, deriving the remote URL and the
  reverse-DNS name rather than leaving two mechanical fields to be got wrong.
  `--verify` calls the endpoint before writing.
- `PhoenixAnalytics.SiteMap`, a bounded in-memory record of what this node has
  served, which is what the built-in tools answer from.
- `PhoenixAnalytics.event/3` for server-side conversions, sent with the request's
  own beacon so they attach to the visit, page and campaign that produced them.
  Events on non-pageview requests are filed against the page the visitor was on
  and consume no pageview number.
- `SSA_COLLECT_URL` support, so self-hosting is one environment variable rather
  than a code change.
- Asynchronous, bounded delivery: a request never waits on a beacon, and a slow
  or failing collector is dropped rather than allowed to grow without limit.
