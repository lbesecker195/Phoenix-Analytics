defmodule PhoenixAnalytics.MCPTest do
  @moduledoc """
  The site as a tool server, and the thing that makes it worth putting in an
  analytics library: the calls are measured on the same visit as the pages.
  """

  use PhoenixAnalytics.ConnCase, async: false

  alias PhoenixAnalytics.SiteMap

  @modern "2026-07-28"
  @legacy "2025-11-25"

  setup do
    SiteMap.reset()
    :ok
  end

  describe "the handshake era" do
    test "initialize answers with this server's identity" do
      result = rpc!("initialize", %{"protocolVersion" => @legacy})

      assert result["protocolVersion"] == @legacy
      assert result["serverInfo"]["name"] == "test-site"
      assert result["serverInfo"]["title"] == "A Test Site"
      assert result["capabilities"]["tools"] == %{}
      assert result["instructions"] =~ "list_pages"
    end

    test "an unknown protocol version falls back rather than failing" do
      result = rpc!("initialize", %{"protocolVersion" => "1999-01-01"})
      assert result["protocolVersion"] == @legacy
    end

    test "ping answers" do
      assert rpc!("ping") == %{}
    end

    test "a notification is acknowledged with no body" do
      conn = post(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

      assert conn.status == 202
      assert conn.resp_body == ""
    end
  end

  describe "the stateless era" do
    test "server/discover replaces the handshake" do
      result = rpc!("server/discover", %{}, @modern)

      assert @modern in result["supportedVersions"]
      assert result["resultType"] == "complete"
      assert result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "test-site"
    end

    test "an unsupported version is refused with what is supported" do
      body = post_body(msg("server/discover", %{"_meta" => meta("2020-01-01")}))

      assert body["error"]["code"] == -32022
      assert @modern in body["error"]["data"]["supported"]
    end

    test "a header that disagrees with the body is refused" do
      # The two say the same thing or the request is malformed; guessing which
      # one meant it would be worse than refusing.
      conn =
        post(msg("tools/list", %{"_meta" => meta(@modern)}), [
          {"mcp-protocol-version", "2024-11-05"}
        ])

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"]["code"] == -32020
    end
  end

  describe "tools" do
    test "every built-in tool is listed with a schema" do
      names = rpc!("tools/list")["tools"] |> Enum.map(& &1["name"])

      assert "list_pages" in names
      assert "read_page" in names
      assert "site_activity" in names
      assert "record_event" in names

      for tool <- rpc!("tools/list")["tools"] do
        assert is_binary(tool["description"]) and tool["description"] != ""
        assert tool["inputSchema"]["type"] == "object"
      end
    end

    test "a host application's own tools are listed alongside them" do
      names =
        rpc!("tools/list", %{}, nil, tools: [PhoenixAnalytics.MCPTest.EchoTool])
        |> Map.fetch!("tools")
        |> Enum.map(& &1["name"])

      assert "echo" in names
      assert "list_pages" in names
    end

    test "list_pages reports what the site has actually served" do
      SiteMap.record("/pricing", "Mozilla/5.0")
      SiteMap.record("/pricing", "GPTBot/1.1")
      SiteMap.record("/docs", "Mozilla/5.0")
      Process.sleep(20)

      pages = call!("list_pages")["structuredContent"]["pages"]

      assert [%{"path" => "/pricing", "requests" => 2, "agent_requests" => 1} | _] = pages
      assert Enum.find(pages, &(&1["path"] == "/docs"))
    end

    test "site_activity splits agents from people" do
      SiteMap.record("/", "Mozilla/5.0")
      SiteMap.record("/", "ClaudeBot/1.0")
      SiteMap.record("/llms.txt", "ClaudeBot/1.0")
      Process.sleep(20)

      activity = call!("site_activity")["structuredContent"]

      assert activity["requests"] == 3
      assert activity["agent_requests"] == 2
      assert activity["browser_requests"] == 1
    end

    test "a tool error is something the model can read, not a protocol failure" do
      result = call!("read_page", %{"path" => "not-a-path"})

      assert result["isError"]
      assert hd(result["content"])["text"] =~ "must begin with"
    end

    test "read_page refuses to read the tool server itself" do
      result = call!("read_page", %{"path" => "/mcp/anything"})

      assert result["isError"]
      assert hd(result["content"])["text"] =~ "own endpoint"
    end

    test "an unknown tool is a protocol error" do
      body = post_body(msg("tools/call", %{"name" => "nope", "arguments" => %{}}))

      assert body["error"]["code"] == -32602
      assert body["error"]["message"] =~ "Unknown tool"
    end

    test "a tool that raises is reported rather than dropped" do
      result =
        call!("boom", %{}, tools: [PhoenixAnalytics.MCPTest.RaisingTool])

      assert result["isError"]
      assert hd(result["content"])["text"] =~ "That tool failed"
    end

    test "results come back as data and as text" do
      result = call!("site_activity")

      assert is_map(result["structuredContent"])
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert {:ok, _} = Jason.decode(text)
    end
  end

  describe "measurement" do
    test "a tool call is recorded against the visit" do
      post(msg("tools/call", %{"name" => "site_activity", "arguments" => %{}}))

      {payload, _} = captured_beacon()

      assert event = Enum.find(payload["e"], &(&1["name"] == "mcp_tool_call"))
      assert event["data"] == %{"tool" => "site_activity"}
    end

    test "an agent's own report of what it did is recorded" do
      post(
        msg("tools/call", %{
          "name" => "record_event",
          "arguments" => %{"name" => "answer_found", "data" => %{"pages_read" => 3}}
        })
      )

      {payload, _} = captured_beacon()
      names = payload["e"] |> Enum.filter(&(&1["n"] == "event")) |> Enum.map(& &1["name"])

      # Both: the call happened, and the agent said what it accomplished.
      assert "mcp_tool_call" in names
      assert "answer_found" in names
    end

    test "a conversation is one visit, not one visit per call" do
      # An agent with no cookies still identifies itself for the length of a
      # conversation. Without this, twenty calls would be twenty sessions.
      post(msg("tools/list"), [{"mcp-session-id", "conversation-1"}])
      {first, _} = captured_beacon()

      post(msg("tools/list"), [{"mcp-session-id", "conversation-1"}])
      {second, _} = captured_beacon()

      assert first["s"] == second["s"]

      post(msg("tools/list"), [{"mcp-session-id", "conversation-2"}])
      {other, _} = captured_beacon()

      refute other["s"] == first["s"]
    end

    test "an agent that browsed first keeps the session it already had" do
      browsing = request_page("/docs")
      cookies = Map.take(resp_cookies(browsing), ["wa_sid", "wa_srv", "wa_vid"])
      {page_beacon, _} = captured_beacon()

      post(msg("tools/list"), [{"mcp-session-id", "conversation-3"}], cookies)
      {tool_beacon, _} = captured_beacon()

      assert tool_beacon["s"] == page_beacon["s"],
             "reading pages and calling tools should be one visit"
    end
  end

  describe "the transport" do
    test "a batch is answered as a batch" do
      conn =
        post([
          msg("ping") |> Map.put("id", 1),
          msg("tools/list") |> Map.put("id", 2)
        ])

      assert [%{"id" => 1}, %{"id" => 2}] = Jason.decode!(conn.resp_body)
    end

    test "malformed JSON is a parse error" do
      conn =
        Plug.Test.conn("POST", "/mcp", "{not json")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> PhoenixAnalytics.MCP.Plug.call(mcp_opts())

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"]["code"] == -32700
    end

    test "GET says where to send requests instead of hanging" do
      conn = Plug.Test.conn("GET", "/mcp") |> PhoenixAnalytics.MCP.Plug.call(mcp_opts())

      assert conn.status == 405
      assert Plug.Conn.get_resp_header(conn, "allow") == ["POST"]
    end

    test "an unknown method is method-not-found" do
      body = post_body(msg("resources/list"))
      assert body["error"]["code"] == -32601
    end
  end

  # -- tools used by these tests -------------------------------------------

  defmodule EchoTool do
    @behaviour PhoenixAnalytics.MCP.Tool

    @impl true
    def definition do
      %{
        "name" => "echo",
        "title" => "Echo",
        "description" => "Returns what it was given.",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    end

    @impl true
    def call(arguments, _ctx), do: {:ok, arguments}
  end

  defmodule RaisingTool do
    @behaviour PhoenixAnalytics.MCP.Tool

    @impl true
    def definition do
      %{
        "name" => "boom",
        "title" => "Boom",
        "description" => "Fails.",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    end

    @impl true
    def call(_arguments, _ctx), do: raise("kaboom")
  end

  # -- helpers -------------------------------------------------------------

  defp mcp_opts(extra \\ []) do
    PhoenixAnalytics.MCP.Plug.init(
      Keyword.merge([name: "test-site", title: "A Test Site"], extra)
    )
  end

  defp msg(method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
  end

  defp meta(version), do: %{"io.modelcontextprotocol/protocolVersion" => version}

  # Runs the MCP plug inside the analytics plug, which is how it is deployed.
  defp post(message, headers \\ [], cookies \\ %{}) do
    Plug.Test.conn("POST", "/mcp", Jason.encode!(message))
    |> Map.put(:host, "www.example.com")
    |> Map.put(:script_name, ["mcp"])
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
    end)
    |> then(fn conn ->
      if map_size(cookies) == 0 do
        conn
      else
        Plug.Conn.put_req_header(
          conn,
          "cookie",
          Enum.map_join(cookies, "; ", fn {k, v} -> "#{k}=#{v}" end)
        )
      end
    end)
    |> PhoenixAnalytics.Plug.call(opts())
    |> PhoenixAnalytics.MCP.Plug.call(mcp_opts())
  end

  defp post_body(message, headers \\ []), do: message |> post(headers) |> body()

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp rpc!(method, params \\ %{}, version \\ nil, opts \\ []) do
    params = if version, do: Map.put(params, "_meta", meta(version)), else: params

    conn =
      Plug.Test.conn("POST", "/mcp", Jason.encode!(msg(method, params)))
      |> Map.put(:script_name, ["mcp"])
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> PhoenixAnalytics.MCP.Plug.call(mcp_opts(opts))

    case body(conn) do
      %{"result" => result} -> result
      other -> flunk("expected a result, got: #{inspect(other)}")
    end
  end

  defp call!(tool, arguments \\ %{}, opts \\ []) do
    rpc!("tools/call", %{"name" => tool, "arguments" => arguments}, nil, opts)
  end

  defp request_page(path) do
    Plug.Test.conn("GET", path)
    |> Map.put(:host, "www.example.com")
    |> PhoenixAnalytics.Plug.call(opts())
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, "<html></html>")
  end
end
