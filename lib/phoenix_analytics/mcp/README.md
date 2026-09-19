# mcp

This application, served as an MCP server — and measured while it is.

[`plug.ex`](plug.ex) is what a host mounts: `forward "/mcp",
PhoenixAnalytics.MCP.Plug, name: "my-site"`. It handles the HTTP side, ties each
call to an analytics session, and records what happened.

[`server.ex`](server.ex) is the protocol, transport-free so it can be tested
without a connection. It speaks two eras at once because clients in the wild are
on both: the stateless 2026-07-28 revision, where `server/discover` replaces the
handshake and the version travels in `_meta`, and the handshake era from
2024-11-05 through 2025-11-25, where `initialize` negotiates and notifications
are acknowledged with 202.

[`tools.ex`](tools.ex) turns a tool's plain return value into a protocol result,
once — a tool with side effects must not be run twice to find out what it wanted
recorded. [`tool.ex`](tool.ex) is the behaviour a host implements to add its own.

[`tools/`](tools) holds the four every installation gets, answerable with no
configuration: what pages this site serves, the text of any of them, how much of
the traffic is agents, and a way for an agent to say what it accomplished.

Why an analytics library ships an MCP server: a tool call is a visit. An agent
that reads three pages and then calls a tool did one thing, and it should read
as one thing.

Related: [Seriously Simple Analytics](https://seriouslysimpleanalytics.com/),
its [own MCP server](https://seriouslysimpleanalytics.com/analytics-mcp-server),
and [MCP Harbor](https://ai.mcpharbor.com/) for listing yours.
