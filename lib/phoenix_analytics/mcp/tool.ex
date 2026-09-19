defmodule PhoenixAnalytics.MCP.Tool do
  @moduledoc """
  A tool an application exposes to agents.

      defmodule MyApp.MCP.SearchServers do
        @behaviour PhoenixAnalytics.MCP.Tool

        @impl true
        def definition do
          %{
            "name" => "search_servers",
            "title" => "Search the registry",
            "description" => "Finds MCP servers by name, capability or transport.",
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

  `call/2` returns plain data. It is wrapped into the protocol's result shape
  for you, including a readable text rendering for clients that only show text,
  so a tool never has to know what a `CallToolResult` looks like.

  Returning `{:error, message}` produces a tool error the model can read and act
  on, which is different from a protocol error and should be preferred for
  anything the caller could fix by trying again differently.

  `ctx` carries `:conn`, `:base_url` and `:session` — the analytics session this
  call belongs to, which is the same session as that agent's page reads when it
  has been reading pages.
  """

  @doc "The MCP tool definition: name, title, description, inputSchema."
  @callback definition() :: map()

  @doc "Runs the tool. Return any JSON-encodable data, or `{:error, message}`."
  @callback call(arguments :: map(), ctx :: map()) :: {:ok, term()} | {:error, String.t()}
end
