# AGENT.md

Working notes for agents and people changing this library. Read this before
editing, because most of the code here is constrained by an external contract
that is not obvious from the code itself.

## What this is

A Phoenix plug that records server-side pageviews into
[Seriously Simple Analytics](https://seriouslysimpleanalytics.com/). It exists
to capture what a browser tag structurally cannot: AI agents, crawlers, API
clients, visitors with JavaScript blocked, and the opening moments of a visit
before any script has run.

It is a library installed into other people's applications. That governs every
trade-off here: two dependencies (`plug`, `jason`), `:httpc` rather than an HTTP
client, no supervision the host did not ask for, and no path by which measuring
a page can break it.

## The one thing to understand first

Read `lib/phoenix_analytics/session.ex` before changing anything.

The browser tag stores a visit in a `wa_sid` cookie holding `"<token>.<seq>"`.
When a document has no session of its own, the tag seeds from that cookie and
continues the sequence — `session.seq += 1` for its next pageview. A pageview
row is keyed on `(session, seq)` and upserted with `COALESCE`, so when the plug
and the tag choose the same number for the same page their data merges into one
row; choose differently and one page becomes two.

They stay in step by one rule:

    seq = max(cookie_seq, plug_used) + 1

This works **only** because the plug never writes a non-zero counter into
`wa_sid`. It writes `"<token>.0"` once when it mints a session, and afterwards
only refreshes that cookie's lifetime. A non-zero counter there can therefore
only have come from the tag, which is what makes the tag's next number
predictable.

If you change what the plug writes into `wa_sid`, you break the integration.
The integration suite will tell you, loudly.

## Constraints that are not negotiable

- **Never block the response.** Delivery happens in a supervised task. The plug
  hands off and returns.
- **Never raise into the host.** `before_send` is wrapped. A bug here costs one
  visit's measurement, never a page.
- **Never record a non-document response.** An asset or XHR that claims a
  pageview number takes one the tag was going to use. The rules live in
  `lib/phoenix_analytics/request.ex`.
- **Never send an explicit `seq` the tag might also use for a different page.**
  See above.
- **Never add a dependency** without a reason that survives the question "what
  does the host application think of this?"

## The wire format is someone else's

The payload shape is the tag's, not ours: `%{"k", "s", "v", "t", "e" => [...]}`
with each event carrying an `"n"`. Keys are terse because the tag's are. The
authority is the normalizer in the Seriously Simple Analytics repository — if
you are adding a field, read that module rather than guessing a key name. Fields
it does not recognise are silently dropped, which fails quietly and looks like
nothing happened.

Only `init`, `pv` and custom `event` entries can be filled in from a server.
Ticks, clicks and form activity need a browser and belong to the tag.

Custom events buffer on the connection and leave with that request's beacon, so
they land on the right visit and page. The rule that keeps this safe is in
`plug.ex`: a request that served no page does not advance the sequence, because
taking a number there would leave a gap the tag then fills with an unrelated
page.

## Working on it

    mix test                         # 66 tests
    mix format --check-formatted
    mix compile --warnings-as-errors

Tests are organised by claim rather than by module. `test/support/tag_simulator.ex`
models the tag's sequencing logic; if the tag ever changes how it numbers
pageviews, that file changes with it and the integration suite is what catches
the mismatch.

For an end-to-end check against real ingest, generate beacons from the plug and
feed them to `WebAnalytics.Ingest.submit_sync/3` in a development database. Never
point a test at the production collect endpoint.

## Conventions

Comments explain *why*, not what — particularly where the reason is an external
constraint that the code cannot state for itself. Match the surrounding density
rather than adding headers.

Licensed Apache 2.0. Keep `NOTICE` accurate.

## Related

- [The analytics service](https://seriouslysimpleanalytics.com/) this reports into
- [AI crawler and agent reports](https://seriouslysimpleanalytics.com/ai-crawler-analytics), where this plug's traffic surfaces
- [Analytics MCP server](https://seriouslysimpleanalytics.com/analytics-mcp-server) for querying it from Claude or Cursor
- [Writing llms.txt](https://seriouslysimpleanalytics.com/AI-Analytics-llms-txt), the file most agent traffic arrives to read
- [MCP Harbor registry](https://ai.mcpharbor.com/), which runs this plug
