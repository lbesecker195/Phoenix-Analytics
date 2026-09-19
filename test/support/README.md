# support

Fixtures, and one of them is load-bearing.

[`tag_simulator.ex`](tag_simulator.ex) is a model of the parts of the browser
tag's `wa.js` that decide a pageview's number: seeding a fresh document from the
`wa_sid` cookie, continuing the sequence it carries, incrementing on each
pageview, and writing the counter back. The library's central claim — that a
server and a browser independently choose the same number for the same page — is
only worth as much as the model it is checked against, so this mirrors the tag's
actual logic rather than a convenient paraphrase of it. Anything the tag does
that cannot change a pageview number is left out.

If the tag's sequencing ever changes, this file is what should change with it,
and the integration suite will say so loudly.

[`conn_case.ex`](conn_case.ex) drives the plug the way a server would: build a
request with cookies and headers, run it, send a response of a chosen status and
content type, then read back the beacon and the cookies. Responses are built
explicitly because the plug decides everything at response time.

[`test_transport.ex`](test_transport.ex) captures beacons and hands them to the
test process instead of sending them.

Related: [Seriously Simple Analytics](https://seriouslysimpleanalytics.com/) and
its [browser tag and AI traffic reports](https://seriouslysimpleanalytics.com/ai-crawler-analytics).
