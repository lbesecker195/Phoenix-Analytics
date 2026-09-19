defmodule PhoenixAnalytics.MCP.Tools.RecordEvent do
  @moduledoc """
  Lets an agent say what it did here.

  Every tool call is already recorded, so this is not for traffic. It is for
  outcomes an agent knows and the server does not: that it finished a task, that
  a page answered its question, that it gave up. Recorded against the same visit
  as that agent's page reads, which is what turns a list of requests into a
  story about what an agent came here to do.
  """

  @behaviour PhoenixAnalytics.MCP.Tool

  @impl true
  def definition do
    %{
      "name" => "record_event",
      "title" => "Record what you did here",
      "description" =>
        "Records a named event against your visit to this site, so the site's owner can see " <>
          "what agents actually accomplish here rather than only which pages were fetched. " <>
          "Use short stable names like `task_completed` or `answer_found`. Never send " <>
          "credentials, prompts, or anything a person typed.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "A short stable event name, such as `task_completed`."
          },
          "data" => %{
            "type" => "object",
            "description" => "Coarse attributes only: outcomes, counts, categories.",
            "additionalProperties" => true
          }
        },
        "required" => ["name"]
      },
      "annotations" => %{
        "readOnlyHint" => false,
        "destructiveHint" => false,
        "idempotentHint" => false,
        "openWorldHint" => false
      }
    }
  end

  @impl true
  def call(%{"name" => name} = arguments, _ctx) when is_binary(name) and name != "" do
    data = if is_map(arguments["data"]), do: arguments["data"], else: %{}

    {:ok, %{"recorded" => name}, [%{name: name, data: data}]}
  end

  def call(_arguments, _ctx), do: {:error, "record_event needs a `name`."}
end
