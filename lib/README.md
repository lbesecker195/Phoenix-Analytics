# lib

The library itself. Everything here is loaded into a host application, so the
code is written to be a guest: two dependencies, no supervision tree the host
did not ask for beyond a task supervisor and one reporter, and no path where a
failure in measurement reaches the page being measured.

Two files sit at this level. [`phoenix_analytics.ex`](phoenix_analytics.ex) is
the public face of the package and the place to start reading.
[`phoenix_analytics/`](phoenix_analytics) holds the working parts: the plug, the
session handshake that keeps this in step with the browser tag, the payload
builder, and delivery.

The shape is deliberately flat. A request enters `PhoenixAnalytics.Plug`, which
registers a callback to run once the response exists — the only moment at which
the status and content type are known, and therefore the only moment at which it
can be said whether a pageview happened at all. From there the work is linear:
resolve the session, extract the request, build the payload, hand it to the
reporter, write the cookies back.

Read [`phoenix_analytics/session.ex`](phoenix_analytics/session.ex) first if you
only read one file. It carries the reasoning that the rest depends on.

Related: [Seriously Simple Analytics](https://seriouslysimpleanalytics.com/) is
the service this reports into, and its
[AI crawler reports](https://seriouslysimpleanalytics.com/ai-crawler-analytics)
are where most of what this plug captures ends up being read.
