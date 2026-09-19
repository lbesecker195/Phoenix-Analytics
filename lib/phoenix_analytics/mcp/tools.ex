defmodule PhoenixAnalytics.MCP.Tools do
  @moduledoc """
  The tool list, and the one place a tool's plain return value becomes a
  protocol result.

  Built-in tools describe the site itself — what pages it serves, what is on
  them, how much of its traffic is agents — and are answerable by any
  application that installs this library, with no configuration. A host adds its
  own by listing modules that implement `PhoenixAnalytics.MCP.Tool`.

  Every result is returned twice: as `structuredContent` for a client that can
  read data, and rendered as text for one that can only show text. Tools do not
  have to think about either.
  """

  alias PhoenixAnalytics.MCP.Tools.ListPages
  alias PhoenixAnalytics.MCP.Tools.ReadPage
  alias PhoenixAnalytics.MCP.Tools.RecordEvent
  alias PhoenixAnalytics.MCP.Tools.SiteActivity

  @builtin [ListPages, ReadPage, SiteActivity, RecordEvent]

  @doc "The built-in tools, which every installation gets."
  def builtin, do: @builtin

  @doc "Definitions for `tools/list`, built-ins first, in a fixed order."
  def definitions(tools) do
    tools
    |> all()
    |> Enum.map(fn module ->
      module.definition() |> Map.take(~w(name title description inputSchema annotations))
    end)
  end

  @doc """
  Calls a tool by name.

  Returns `{:ok, CallToolResult, events}` or `{:error, :unknown_tool}`. A tool
  that returns `{:error, message}` produces a result marked `isError`, which the
  model can read and act on — that is a different thing from a protocol error
  and the right answer for anything the caller could fix by asking differently.
  """
  def call(name, arguments, ctx) do
    case Enum.find(all(ctx.tools), &(&1.definition()["name"] == name)) do
      nil ->
        {:error, :unknown_tool}

      module ->
        {result, events} = invoke(module, arguments, ctx)
        {:ok, result, events}
    end
  end

  defp all(tools), do: @builtin ++ List.wrap(tools)

  # Called exactly once. A tool may have side effects, and running it a second
  # time to find out what it wanted recorded would perform them twice.
  defp invoke(module, arguments, ctx) do
    case module.call(arguments, ctx) do
      {:ok, data} -> {success(data), []}
      {:ok, data, events} when is_list(events) -> {success(data), events}
      {:error, message} -> {failure(message), []}
    end
  rescue
    # A tool raising is the host application's bug, not the protocol's, and the
    # model is better served by being told than by a dropped connection.
    error ->
      {failure("That tool failed: #{Exception.message(error)}"), []}
  end

  defp success(data) do
    %{
      "content" => [%{"type" => "text", "text" => render(data)}],
      "structuredContent" => jsonable(data)
    }
  end

  defp failure(message) do
    %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}
  end

  # Text for clients that show text. JSON is honest, readable, and unambiguous
  # about structure, which matters more here than prose would.
  defp render(data) when is_binary(data), do: data

  defp render(data) do
    case Jason.encode(jsonable(data), pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(data)
    end
  end

  defp jsonable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp jsonable(%Date{} = value), do: Date.to_iso8601(value)
  defp jsonable(%{__struct__: _} = value), do: value |> Map.from_struct() |> jsonable()

  defp jsonable(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  defp jsonable(value) when is_tuple(value), do: value |> Tuple.to_list() |> jsonable()
  defp jsonable(value), do: value
end
