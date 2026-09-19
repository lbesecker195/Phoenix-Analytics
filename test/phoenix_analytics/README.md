# phoenix_analytics tests

One file per claim.

[`integration_test.exs`](integration_test.exs) is the headline. It drives whole
visits rather than single requests and asserts that the plug and the browser tag
agree on every pageview number — first page, second, third — in both the
tag-present and no-JavaScript cases. It also covers page flow, session
continuity, and the rule that whoever opens a session owes the `init` event.

[`trackable_test.exs`](trackable_test.exs) draws the line around what counts as
a page: navigations yes, stylesheets and background fetches no, redirects and
errors no, and — the case that justifies the library — an agent reading
`llms.txt` or a JSON endpoint yes.

[`session_test.exs`](session_test.exs) is the unit-level companion to the
handshake: cookie parsing, malformed values, counter precedence, cookie scope,
and the registrable-domain guess that decides whether a visit survives a hop
between subdomains.

[`payload_test.exs`](payload_test.exs) checks what the server contributes that a
browser cannot — full URL, campaign, response timing — and that nothing empty is
sent. [`transport_http_test.exs`](transport_http_test.exs) puts real bytes on a
real socket. [`config_test.exs`](config_test.exs) covers deferred settings and
self-hosting.

Related: the
[collect API and llms.txt guidance](https://seriouslysimpleanalytics.com/AI-Analytics-llms-txt)
these are written against, and
[the analytics service](https://seriouslysimpleanalytics.com/) itself.
