defmodule PhoenixAnalytics.MCP.Tools.SiteActivity do
  @moduledoc """
  How much of this site's traffic is agents rather than people.

  Answered from what this node has served since it started, which is the only
  thing a library with no database can answer honestly. The durable history
  lives in the analytics account.
  """

  @behaviour PhoenixAnalytics.MCP.Tool

  alias PhoenixAnalytics.SiteMap

  @impl true
  def definition do
    %{
      "name" => "site_activity",
      "title" => "How busy this site is, and who with",
      "description" =>
        "Summarises what this site has served recently: how many pages, how many requests, and " <>
          "the split between agents and crawlers on one side and browsers on the other. Covers " <>
          "this server process only; the full history is in the analytics account.",
      "inputSchema" => %{"type" => "object", "properties" => %{}},
      "annotations" => %{
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false
      }
    }
  end

  @impl true
  def call(_arguments, _ctx) do
    activity = SiteMap.activity()

    {:ok,
     %{
       "pages" => activity.pages,
       "requests" => activity.requests,
       "agent_requests" => activity.agent_requests,
       "browser_requests" => activity.browser_requests,
       "since" => activity.since && DateTime.to_iso8601(activity.since),
       "scope" => "this server process"
     }}
  end
end
