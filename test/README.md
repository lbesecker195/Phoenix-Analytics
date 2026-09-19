# test

The suite is organised around the claims the library makes, not around its
modules, because the failure worth guarding against is drift between two halves
of a system rather than a broken function.

[`phoenix_analytics/integration_test.exs`](phoenix_analytics/integration_test.exs)
is the one that matters. It walks whole visits — three pages, with and without
JavaScript — and checks that the plug and the browser tag pick the same pageview
number for the same page every time. A test of a single call would pass while the
two slid apart by the third page.

[`phoenix_analytics/trackable_test.exs`](phoenix_analytics/trackable_test.exs)
covers what is recorded and what is not. Over-recording is the expensive
mistake: an asset that claims a pageview number takes one the tag was going to
use.

[`phoenix_analytics/session_test.exs`](phoenix_analytics/session_test.exs)
exercises cookie parsing against malformed input, all of which is reachable by
anyone who cares to try.
[`transport_http_test.exs`](phoenix_analytics/transport_http_test.exs) runs the
real transport against a real socket.
[`../test/phoenix_analytics_test.exs`](phoenix_analytics_test.exs) checks the
promise that measurement can fail without the page failing.

[`support/`](support) holds the fixtures, including a model of the browser tag's
sequencing logic.

Related: [Seriously Simple Analytics](https://seriouslysimpleanalytics.com/),
whose ingest contract these tests are written against.
