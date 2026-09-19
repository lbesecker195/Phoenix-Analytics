defmodule PhoenixAnalytics.MCP.Plug do
  @moduledoc """
  Serves this application as an MCP server, and measures what agents do with it.

  Mount it anywhere in a router:

      forward "/mcp", PhoenixAnalytics.MCP.Plug,
        name: "mcp-harbor",
        title: "MCP Harbor — the registry of MCP servers",
        tools: [MyApp.MCP.SearchServers]

  Out of the box, with no tools of your own, an agent can already ask what pages
  this site serves, read any of them as clean text, and see how much of the
  site's traffic is agents rather than people. Those answers come from what this
  node has actually served, so they need no configuration and cannot drift out
  of date the way a hand-written manifest does.

  ## Why this lives in an analytics library

  Because a tool call is a visit, and until now it was an unmeasurable one. An
  agent that reads three pages of your documentation and then calls one of your
  tools has done one coherent thing, but the pages land in analytics and the
  tool call lands in a log, if anywhere. Here they land together: every call is
  recorded against the same session as that agent's page reads, so the report
  shows what agents came to do and whether they managed it, not just which URLs
  were fetched.

  Sessions join up two ways. A caller carrying this site's cookies — an agent
  that browsed first — continues that visit. A caller carrying only an MCP
  session id gets a session derived from it, so a conversation of twenty calls
  is one visit rather than twenty.

  ## Requirements

  `PhoenixAnalytics.Plug` must be installed in the endpoint, since that is what
  sends what this records. Without it, the MCP server still works; nothing is
  measured.
  """

  @behaviour Plug

  alias PhoenixAnalytics.MCP.Server

  @version "0.1.0"

  @impl true
  def init(opts) do
    %{
      name: Keyword.get(opts, :name, "phoenix-analytics"),
      title: Keyword.get(opts, :title),
      version: Keyword.get(opts, :version, @version),
      instructions: Keyword.get(opts, :instructions),
      tools: Keyword.get(opts, :tools, []),
      website_url: Keyword.get(opts, :website_url)
    }
  end

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, opts) do
    {conn, body} = read_message(conn)

    case body do
      {:ok, message} -> respond(conn, message, opts)
      {:error, reason} -> send_json(conn, 400, parse_error(reason))
    end
  end

  # The streaming half of the transport. This server answers every request in
  # the response to that request, so there is nothing to stream, and saying so
  # is friendlier than leaving a client waiting on an open socket.
  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("allow", "POST")
    |> send_json(405, %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{
        "code" => -32600,
        "message" => "This server answers on POST. There is no event stream to open."
      }
    })
  end

  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("allow", "POST, OPTIONS")
    |> Plug.Conn.send_resp(204, "")
  end

  def call(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("allow", "POST, OPTIONS")
    |> send_json(405, %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32600, "message" => "Use POST."}
    })
  end

  # -- dispatch ------------------------------------------------------------

  defp respond(conn, message, opts) do
    conn = put_session_token(conn)
    ctx = context(conn, opts)

    {status, body, events} =
      case message do
        messages when is_list(messages) -> batch(messages, ctx)
        message -> Server.handle(message, ctx)
      end

    conn
    |> record(message, events)
    |> send_json(status, body)
  end

  # A batch is answered as a batch. Notifications contribute no answer, so a
  # batch of nothing but notifications is acknowledged with no body at all.
  defp batch(messages, ctx) do
    {bodies, events} =
      Enum.reduce(messages, {[], []}, fn message, {bodies, events} ->
        {_status, body, message_events} = Server.handle(message, ctx)
        {if(body, do: [body | bodies], else: bodies), events ++ message_events}
      end)

    case Enum.reverse(bodies) do
      [] -> {202, nil, events}
      answers -> {200, answers, events}
    end
  end

  defp context(conn, opts) do
    base_url = base_url(conn)

    %{
      conn: conn,
      headers: headers(conn),
      base_url: base_url,
      mount_path: mount_path(conn),
      tools: opts.tools,
      instructions: opts.instructions || instructions(opts),
      server_info: server_info(opts, base_url)
    }
  end

  defp server_info(opts, base_url) do
    %{"name" => opts.name, "version" => opts.version}
    |> put_unless_nil("title", opts.title)
    |> put_unless_nil("websiteUrl", opts.website_url || base_url)
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp instructions(opts) do
    name = opts.title || opts.name

    "Tools for #{name}. Start with `list_pages` to see what this site covers, then " <>
      "`read_page` to read any of it as clean text. `site_activity` reports how much of this " <>
      "site's traffic comes from agents. If you finish something here, say so with " <>
      "`record_event` — it is how this site learns whether agents are getting what they came for."
  end

  # -- measurement ---------------------------------------------------------

  # An agent with no cookies still has an identity for the length of its
  # conversation. Using it means twenty calls read as one visit.
  defp put_session_token(conn) do
    case Plug.Conn.get_req_header(conn, "mcp-session-id") do
      [id | _] when is_binary(id) and id != "" ->
        Plug.Conn.put_private(
          conn,
          :phoenix_analytics_session_token,
          PhoenixAnalytics.Session.token_from(id)
        )

      _ ->
        conn
    end
  end

  # Every call is recorded, named for the method and the tool. A tool may also
  # ask for events of its own, which is how an agent reports an outcome the
  # server has no way to observe.
  defp record(conn, message, events) do
    conn
    |> record_calls(message)
    |> record_events(events)
  end

  defp record_calls(conn, messages) when is_list(messages),
    do: Enum.reduce(messages, conn, &record_calls(&2, &1))

  defp record_calls(conn, %{"method" => "tools/call", "params" => %{"name" => name}})
       when is_binary(name) do
    PhoenixAnalytics.event(conn, "mcp_tool_call", data: %{"tool" => name}, trigger: "mcp")
  end

  defp record_calls(conn, %{"method" => method}) when is_binary(method) do
    PhoenixAnalytics.event(conn, "mcp_request", data: %{"method" => method}, trigger: "mcp")
  end

  defp record_calls(conn, _message), do: conn

  defp record_events(conn, events) do
    Enum.reduce(events, conn, fn event, acc ->
      PhoenixAnalytics.event(acc, event.name, data: Map.get(event, :data, %{}), trigger: "mcp")
    end)
  end

  # -- http ----------------------------------------------------------------

  # Plug.Parsers may already have decoded the body, in which case reading it
  # again returns nothing. Both cases have to work, because where this is
  # mounted is the host's choice.
  defp read_message(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    case Plug.Conn.read_body(conn, length: 2_000_000) do
      {:ok, "", conn} -> {conn, {:error, :empty}}
      {:ok, body, conn} -> {conn, decode(body)}
      {:more, _partial, conn} -> {conn, {:error, :too_large}}
      {:error, reason} -> {conn, {:error, reason}}
    end
  end

  defp read_message(conn) do
    case conn.body_params do
      params when params == %{} -> {conn, {:error, :empty}}
      params -> {conn, {:ok, params}}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :malformed}
    end
  end

  defp parse_error(:empty) do
    %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32700, "message" => "Parse error: the request had no body"}
    }
  end

  defp parse_error(:too_large) do
    %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32700, "message" => "Parse error: that request is too large"}
    }
  end

  defp parse_error(_) do
    %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32700, "message" => "Parse error: expected JSON"}
    }
  end

  defp send_json(conn, status, nil), do: Plug.Conn.send_resp(conn, status, "")

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp headers(conn) do
    Map.new(conn.req_headers, fn {name, value} -> {String.downcase(name), value} end)
  end

  defp base_url(conn) do
    port =
      case {conn.scheme, conn.port} do
        {:http, 80} -> ""
        {:https, 443} -> ""
        {_, port} when is_integer(port) -> ":#{port}"
        _ -> ""
      end

    "#{conn.scheme}://#{conn.host}#{port}"
  end

  # Where this plug was forwarded to, so `read_page` can refuse to read it.
  defp mount_path(conn) do
    case conn.script_name do
      [] -> "/mcp"
      segments -> "/" <> Enum.join(segments, "/")
    end
  end
end
