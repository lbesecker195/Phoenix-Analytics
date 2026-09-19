# PhoenixAnalytics

**Server-side analytics middleware for Phoenix.** A plug that records the
traffic your JavaScript tag cannot see — AI agents, crawlers, scripts and API
clients — and folds it into the same
[Seriously Simple Analytics](https://seriouslysimpleanalytics.com) session the
browser tag is already reporting.

One visit stays one visit. Add the plug to a site already running the tag and
your numbers do not double.

```elixir
def deps do
  [{:phoenix_analytics_middleware, "~> 0.1"}]
end
```

```elixir
# lib/my_app_web/endpoint.ex — below Plug.Static, above the router
plug PhoenixAnalytics.Plug, site: {:system, "SSA_SITE_KEY"}
```

That is the whole installation. There is no database to run, no schema to
migrate and no second dashboard to check.

---

## Why a server-side plug at all

A browser tag has to load and execute before it can report. Everything that
never executes JavaScript is therefore invisible to it, and that blind spot is
no longer a rounding error:

| Visitor | Browser tag | This plug |
| --- | --- | --- |
| A person browsing | Everything — scroll, dwell, clicks, paint timing | The request, the referrer, the response time |
| A person with JavaScript blocked | **Nothing** | The full visit |
| An AI agent or crawler | **Nothing** | The full visit |
| A script or API client | **Nothing** | The full visit |
| A person who leaves before the tag loads | **Nothing** | Landing page, referrer, campaign |

The plug is not a replacement for the tag and does not try to be. The tag
measures what a browser is uniquely placed to measure, and it does it better
than any server can. This fills in what is structurally invisible from there.

Run both and you get the whole picture. Run only the plug — on an API, an MCP
server, a docs site, anything with no browser around it — and you still get
sessions, referrers, campaigns and page flow.

## How one visit stays one visit

This is the part worth understanding, because it is where a naive
server-side tracker doubles your traffic.

The tag keeps a visit in a `wa_sid` cookie holding `"<token>.<seq>"`, where
`seq` is the highest pageview number used so far. When a document has no session
of its own, the tag seeds from that cookie and *continues* the sequence.

A pageview is stored against `(session, seq)` and upserted with `COALESCE`. So
when the plug and the tag pick the **same number for the same page**, their data
merges into one row — the server contributing the URL, referrer and response
timing, the browser contributing scroll depth, dwell and paint timing. Pick
different numbers and one page becomes two rows.

They stay in step by one rule:

```
seq = max(cookie_seq, plug_used) + 1
```

It works because the plug never writes a non-zero counter into `wa_sid`. It
writes `"<token>.0"` once, when it opens a session, and afterwards only refreshes
that cookie's lifetime. A non-zero counter there can only have come from the tag
— which tells the plug exactly which number the tag is about to use.

- **Tag present.** The first request opens the session at `.0`, so the tag seeds
  from `0` and numbers the landing page `1` — the number the plug just used. From
  there both read the tag's counter and both land on the next number.
- **No tag.** `wa_sid` stays at `0`, numbering falls to the plug's own counter,
  and the visit is sequenced `1, 2, 3` by the server alone.

### Page flow without a browser

A visit is only a path through your site if each page knows the one before it.
The collect endpoint chains that for callers who let it assign pageview numbers,
which this plug deliberately does not — so it chains its own: a same-site
`Referer` when the browser reports a real navigation, and the last page the plug
recorded otherwise. An agent walking your docs shows up as a route through them,
not three unrelated landings.

A visit is also *opened earlier* than the tag could manage. A session the plug
mints already carries its landing page, referrer and campaign before a byte of
JavaScript has run, so a visitor who bounces in two seconds is still a visit
with a source attached.

## What gets recorded

Recording too much is the expensive mistake: an asset that claims a pageview
number takes one the tag was going to use. So the test differs by client, on
purpose.

- **Browsers** send `sec-fetch-dest`, which says what a response is *for*. When
  it is present it is believed absolutely — `document` is a navigation,
  everything else is a subresource or a background fetch. That is exactly when
  the tag opens a pageview too.
- **Everything else** sends no such header and is judged on what it received: a
  successful `GET` of something readable. An agent reading `llms.txt` or a JSON
  endpoint is doing the thing this library exists to see, and no browser-shaped
  test would count it.

Redirects, `404`s, `POST`s, images and binary downloads are never recorded.

## Server-side events

Conversions usually complete on the server — a payment clears, a signup writes a
row, an API key is issued. Record them where they actually happen:

```elixir
conn
|> PhoenixAnalytics.event("signup_completed", data: %{plan: "team"})
|> redirect(to: ~p"/welcome")
```

The event is not sent on its own. It rides out with the beacon the plug already
sends for that request, which is what attaches it to the right visit and the
right page — a conversion you cannot trace to a page and a campaign is a number
without a cause.

It works on requests that are not pageviews. A `POST` ending in a redirect
records no page of its own, but an event on it is filed against the page the
visitor was on when they submitted, and takes no pageview number the tag was
going to use.

Because it returns a connection, the caller has to keep it. An event recorded on
a connection that is then thrown away never happened.

Keep `:data` coarse — plans, counts, outcomes. It is stored and displayed, so
never credentials, never prompts, never anything a person typed into a field.

## Your site as an MCP server

Agents are already reading your site. This lets them *use* it — and, unusually,
measures them doing so.

```elixir
forward "/mcp", PhoenixAnalytics.MCP.Plug,
  name: "my-site",
  title: "My Site",
  tools: [MyApp.MCP.SearchThings]
```

With no tools of your own, an agent can already ask what pages the site serves,
read any of them as clean text, and see how much of the traffic is agents rather
than people. Those answers are built from what the site has actually served, so
they need no configuration and cannot go stale the way a hand-written manifest
does.

Adding your own is a module:

```elixir
defmodule MyApp.MCP.SearchThings do
  @behaviour PhoenixAnalytics.MCP.Tool

  @impl true
  def definition do
    %{
      "name" => "search_things",
      "title" => "Search things",
      "description" => "Finds things by name.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      }
    }
  end

  @impl true
  def call(%{"query" => query}, _ctx), do: {:ok, MyApp.search(query)}
end
```

Return plain data; the protocol shape is added for you, including a text
rendering for clients that only show text.

### Letting agents find it

Mounting the plug makes a site callable. It does not make it findable — an agent
has to be told the server exists, and registries are how. Generate the
descriptor one reads:

```bash
mix phoenix_analytics.server_json --url https://example.com --verify
```

`--verify` calls the endpoint first and reports the tools that answered, so a
descriptor is never published pointing at a server that is not there. Publish
the result to [MCP Harbor](https://ai.mcpharbor.dev/), which takes the file
as-is.

### Why this belongs in an analytics library

Because a tool call is a visit, and until now it was an unmeasurable one. An
agent that reads three pages of your documentation and then calls one of your
tools has done one coherent thing — but the pages land in analytics and the tool
call lands in a log, if anywhere.

Here they land together. Every call is recorded against the same session as that
agent's page reads, so you can see what agents came to do and whether they
managed it, not just which URLs were fetched. Sessions join up two ways: a
caller carrying your cookies continues the visit it already has, and a caller
carrying only an MCP session id gets a stable session derived from it — so a
conversation of twenty calls is one visit, not twenty.

Both protocol eras are spoken: the stateless 2026-07-28 revision and the
handshake era from 2024-11-05 through 2025-11-25.

## Configuration

| Option | Default | Notes |
| --- | --- | --- |
| `:site` | — | **Required.** Site key. Accepts `{:system, "VAR"}` or a zero-arity function. |
| `:endpoint` | `SSA_COLLECT_URL`, else the hosted URL | Self-hosting needs the environment variable, not a code change. |
| `:enabled` | `true` | Set `false` for test suites and review apps. |
| `:ignore_paths` | `[]` | Prefixes, regexes or predicates. Health checks and webhooks belong here. |
| `:cookie_domain` | registrable domain | Must match the tag's scope. |
| `:session_timeout_min` | `30` | Must match the tag's `data-session-timeout-min`. |
| `:forward_client_ip` | `true` | Pass the visitor's address to the endpoint. |
| `:transport` | `Transport.HTTP` | Swap for a custom `PhoenixAnalytics.Transport`. |

Anything here can also live in application config:

```elixir
config :phoenix_analytics_middleware,
  site: System.get_env("SSA_SITE_KEY"),
  ignore_paths: ["/health", ~r{^/internal/}]
```

### Geolocation behind a proxy

The beacon is posted by your server, so left alone every visitor would resolve
to your data centre. The plug forwards the visitor's address as
`x-forwarded-for` and copies their CDN geolocation headers verbatim.

The collect endpoint applies its own proxy policy to that header and only
trusts it when the deployment is configured to sit behind a proxy
(`SSA_TRUST_PROXY`). Without it the visit still records, geolocated to your
application's own address.

## Operational promises

Measurement must never be why a page is slow, and never why a page fails.

- **Nothing blocks the response.** Delivery happens in a supervised task; the
  request returns immediately.
- **Nothing propagates.** A failing transport, a malformed header or a bad
  matcher costs that visit's measurement and nothing else. The page still
  renders.
- **Nothing grows without limit.** Delivery is bounded; under saturation the
  newest beacons are dropped rather than queued forever.
- **Two dependencies.** `plug` and `jason`. The default transport is `:httpc`,
  which ships with Erlang, because this installs into applications that did not
  ask for an HTTP client.

Telemetry is emitted as `[:phoenix_analytics, :beacon, :sent | :failed |
:dropped]`, so you can alarm on losing visibility.

## Privacy

The plug sends no request bodies, no form contents, no headers beyond the user
agent, referrer, language and geolocation hints, and no raw address into
storage — the endpoint salts and hashes it, or masks it, in the request that
carried it. Cookies hold a random session token and a random visitor id, and
nothing else.

## Repository map

Each directory carries its own README.

- [`lib/`](lib) — the library, written to be a guest in someone else's app
- [`lib/phoenix_analytics/`](lib/phoenix_analytics) — the working parts, in the order a request meets them
- [`lib/phoenix_analytics/transport/`](lib/phoenix_analytics/transport) — delivery, and carrying the visitor's identity with it
- [`lib/mix/tasks/`](lib/mix/tasks) — the server.json generator for listing a mounted site
- [`test/`](test) — organised by claim rather than by module
- [`AGENT.md`](AGENT.md) — read before changing the session handshake

## Related

- [Seriously Simple Analytics](https://seriouslysimpleanalytics.com) — the
  privacy-first web analytics this plug reports into.
- [AI crawler and agent traffic reports](https://seriouslysimpleanalytics.com/ai-crawler-analytics)
  — which models and bots are reading your pages, and what they read.
- [Analytics MCP server](https://seriouslysimpleanalytics.com/analytics-mcp-server)
  — query these same numbers from Claude, Cursor or VS Code.
- [Writing an llms.txt for AI visibility](https://seriouslysimpleanalytics.com/AI-Analytics-llms-txt)
  — the file most of this plug's non-browser traffic comes to read.
- [MCP Harbor registry](https://ai.mcpharbor.dev/) — where the analytics MCP
  server is listed alongside other tools agents can call.

## Contributing and support

Issues and pull requests are welcome on
[GitHub](https://github.com/lbesecker195/Phoenix-Analytics). For
anything you would rather not file in public — a deployment question, a
self-hosted endpoint, a traffic pattern that looks wrong — write to
**me@LoganBesecker.com** and include your site key so the visit can be traced.

## License

Apache 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
