# phoenix_analytics

The working parts, in the order a request meets them.

[`plug.ex`](plug.ex) is the entry point and the only module a host application
names. It defers everything to the response, because a pageview cannot be
recognised from a request alone.

[`request.ex`](request.ex) decides whether a response was a page and pulls out
what the server can see. The decision differs by client on purpose: browsers say
what a response is for via `sec-fetch-dest` and are believed absolutely;
everything else is judged on whether it successfully fetched something readable.
That second branch is the whole point of the library — it is how an agent
reading `llms.txt` gets counted.

[`session.ex`](session.ex) is the heart of it. It reads the same cookie the
browser tag writes and works out which pageview number the tag is about to use,
so both halves describe one visit instead of two. The reasoning is written out
in full there.

[`payload.ex`](payload.ex) assembles the beacon in the tag's own wire format.
[`config.ex`](config.ex) resolves settings, including values deferred to the
environment. [`reporter.ex`](reporter.ex) and [`transport/`](transport) deliver
it without the request ever waiting.

Related: the
[analytics MCP server](https://seriouslysimpleanalytics.com/analytics-mcp-server)
queries the data this produces, and
[the service itself](https://seriouslysimpleanalytics.com/) explains what is
stored.
