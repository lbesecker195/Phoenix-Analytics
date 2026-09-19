defmodule PhoenixAnalytics.MCP.Tools.ListPages do
  @moduledoc """
  The pages this site actually serves, ranked by how often they are asked for.

  An agent arriving at a site it has never seen has no way to know what is on
  it. A sitemap says what exists; this says what is *read*, which is a better
  starting point and needs no configuration to stay true.
  """

  @behaviour PhoenixAnalytics.MCP.Tool

  alias PhoenixAnalytics.SiteMap

  @impl true
  def definition do
    %{
      "name" => "list_pages",
      "title" => "List the pages on this site",
      "description" =>
        "Lists the pages this site serves, most-requested first, with how many requests each " <>
          "has had and how much of that came from agents and crawlers rather than browsers. " <>
          "Use this first to find out what is on a site before reading anything.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "limit" => %{
            "type" => "integer",
            "description" => "How many pages to return. Defaults to 50.",
            "minimum" => 1,
            "maximum" => 500
          }
        }
      },
      "annotations" => %{
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false
      }
    }
  end

  @impl true
  def call(arguments, _ctx) do
    limit = arguments |> Map.get("limit", 50) |> clamp()

    {:ok,
     %{
       "pages" =>
         Enum.map(SiteMap.pages(limit), fn page ->
           %{
             "path" => page.path,
             "requests" => page.requests,
             "agent_requests" => page.agent_requests,
             "last_seen" => DateTime.to_iso8601(page.last_seen)
           }
         end)
     }}
  end

  defp clamp(value) when is_integer(value), do: value |> max(1) |> min(500)
  defp clamp(_), do: 50
end
