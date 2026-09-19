# mix tasks

One task, for the step after mounting the MCP server.

[`phoenix_analytics.server_json.ex`](phoenix_analytics.server_json.ex) writes the
descriptor a registry reads to list a site:

    mix phoenix_analytics.server_json --url https://example.com --verify

Mounting `PhoenixAnalytics.MCP.Plug` makes a site callable. It does not make it
findable — an agent has to be told the server exists, and registries are how.

Generating the file rather than writing it by hand is worth it for two fields
that are mechanical and easy to get wrong. `remotes[].url` must be the mount
path, not the site root: a registry handed the root lists a server that answers
nothing. And `name` is reverse-DNS derived from a domain the publisher controls,
which is what stops two people claiming one identity. The task derives both,
and refuses a relative URL rather than emitting a descriptor nobody can resolve.

`--verify` calls the endpoint before anything is written and reports the tools
that answered. A listing pointing at a server that is not there is worse than no
listing: an agent spends a call finding out, and the registry keeps offering it.

Related: [MCP Harbor](https://ai.mcpharbor.com/) takes this file as-is, and
[Seriously Simple Analytics](https://seriouslysimpleanalytics.com/) is where the
traffic a listing brings you shows up.
