defmodule PhoenixAnalytics.MCP.Server do
  @moduledoc """
  The Model Context Protocol, spoken on behalf of a host application.

  Transport-free: it takes one decoded JSON-RPC message and a context and
  returns a status and a body, so the protocol can be tested without a
  connection and `PhoenixAnalytics.MCP.Plug` stays a shell.

  Two eras of the protocol are spoken at once, because clients in the wild are
  on both:

    * **Stateless (2026-07-28).** No handshake. Every request carries its
      protocol version in `params._meta`, `server/discover` replaces
      `initialize`, and every result says `resultType: "complete"`.
    * **Handshake (2024-11-05 to 2025-11-25).** `initialize` negotiates a
      version, notifications are acknowledged with 202, and `ping` exists.

  A request belongs to the new era if and only if it carries
  `io.modelcontextprotocol/protocolVersion` in `_meta`. That field is required
  there and unknown in the old one, so the test cannot misfire.

  No session state is held here. What ties one agent's calls together is the
  analytics session on the context, which is resolved from the request the same
  way a pageview's is.
  """

  alias PhoenixAnalytics.MCP.Tools

  @modern_versions ["2026-07-28"]
  @legacy_versions ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

  @doc "Every protocol version this server speaks, newest first."
  def supported_versions, do: @modern_versions ++ @legacy_versions

  @doc "What this server tells a model it can do."
  def capabilities, do: %{"tools" => %{}}

  @doc """
  Handles one JSON-RPC message.

  Returns `{status, body, events}`. `events` are analytics events the call
  produced, for the caller to record against the visit; a nil body means the
  response has none.
  """
  def handle(%{"jsonrpc" => "2.0", "method" => method} = message, ctx) when is_binary(method) do
    params = if is_map(message["params"]), do: message["params"], else: %{}
    meta = if is_map(params["_meta"]), do: params["_meta"], else: %{}

    request = %{
      id: message["id"],
      notification?: not Map.has_key?(message, "id"),
      method: method,
      params: params
    }

    case meta["io.modelcontextprotocol/protocolVersion"] do
      version when is_binary(version) -> modern(request, version, ctx)
      _ -> legacy(request, ctx)
    end
  end

  # A client's answer to a request this server never sends.
  def handle(%{"jsonrpc" => "2.0", "id" => _} = message, _ctx)
      when is_map_key(message, "result") or is_map_key(message, "error") do
    {202, nil, []}
  end

  def handle(_message, _ctx) do
    {400, error(nil, -32600, "Invalid Request: expected a JSON-RPC 2.0 request object"), []}
  end

  # -- 2026-07-28 ----------------------------------------------------------

  defp modern(request, version, ctx) do
    cond do
      mismatch?(ctx, "mcp-protocol-version", version) ->
        {400, error(request.id, -32020, "MCP-Protocol-Version header does not match _meta"), []}

      mismatch?(ctx, "mcp-method", request.method) ->
        {400, error(request.id, -32020, "Mcp-Method header does not match the request method"),
         []}

      version not in @modern_versions ->
        {400,
         error(request.id, -32022, "Unsupported protocol version", %{
           "supported" => supported_versions(),
           "requested" => version
         }), []}

      request.notification? ->
        {202, nil, []}

      true ->
        case dispatch(request, ctx) do
          {:ok, result, events} ->
            {200, reply(request.id, complete(result, ctx)), events}

          {:error, :method_not_found} ->
            {404, error(request.id, -32601, "Method not found: #{request.method}"), []}

          {:error, code, message} ->
            {200, error(request.id, code, message), []}
        end
    end
  end

  defp mismatch?(ctx, header, expected) do
    case header(ctx, header) do
      nil -> false
      value -> value != expected
    end
  end

  defp complete(result, ctx) do
    result
    |> Map.put("resultType", "complete")
    |> Map.update(
      "_meta",
      %{"io.modelcontextprotocol/serverInfo" => ctx.server_info},
      &Map.put(&1, "io.modelcontextprotocol/serverInfo", ctx.server_info)
    )
  end

  # -- 2024-11-05 through 2025-11-25 --------------------------------------

  defp legacy(request, ctx) do
    header_version = header(ctx, "mcp-protocol-version")

    cond do
      header_version && header_version not in @legacy_versions ->
        {400,
         error(request.id, -32600, "Unsupported MCP-Protocol-Version: #{header_version}", %{
           "supported" => supported_versions()
         }), []}

      request.notification? ->
        {202, nil, []}

      true ->
        case dispatch(request, ctx) do
          {:ok, result, events} ->
            {200, reply(request.id, result), events}

          {:error, :method_not_found} ->
            {200, error(request.id, -32601, "Method not found: #{request.method}"), []}

          {:error, code, message} ->
            {200, error(request.id, code, message), []}
        end
    end
  end

  # -- methods -------------------------------------------------------------

  defp dispatch(%{method: "initialize", params: params}, ctx) do
    requested = params["protocolVersion"]
    version = if requested in @legacy_versions, do: requested, else: hd(@legacy_versions)

    {:ok,
     %{
       "protocolVersion" => version,
       "capabilities" => capabilities(),
       "serverInfo" => ctx.server_info,
       "instructions" => ctx.instructions
     }, []}
  end

  defp dispatch(%{method: "ping"}, _ctx), do: {:ok, %{}, []}

  defp dispatch(%{method: "server/discover"}, ctx) do
    {:ok,
     %{
       "supportedVersions" => supported_versions(),
       "capabilities" => capabilities(),
       "instructions" => ctx.instructions
     }, []}
  end

  defp dispatch(%{method: "tools/list"}, ctx) do
    {:ok, %{"tools" => Tools.definitions(ctx.tools)}, []}
  end

  defp dispatch(%{method: "tools/call", params: params}, ctx) do
    case params do
      %{"name" => name} when is_binary(name) ->
        arguments = if is_map(params["arguments"]), do: params["arguments"], else: %{}

        case Tools.call(name, arguments, ctx) do
          {:ok, result, events} -> {:ok, result, events}
          {:error, :unknown_tool} -> {:error, -32602, "Unknown tool: #{name}"}
        end

      _ ->
        {:error, -32602, "tools/call needs a tool name"}
    end
  end

  defp dispatch(_request, _ctx), do: {:error, :method_not_found}

  # -- shapes --------------------------------------------------------------

  defp header(ctx, name), do: Map.get(ctx.headers, name)

  defp reply(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error(id, code, message, data \\ nil) do
    body = %{"code" => code, "message" => message}
    body = if data, do: Map.put(body, "data", data), else: body
    %{"jsonrpc" => "2.0", "id" => id, "error" => body}
  end
end
