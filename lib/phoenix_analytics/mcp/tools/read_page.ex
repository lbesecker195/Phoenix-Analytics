defmodule PhoenixAnalytics.MCP.Tools.ReadPage do
  @moduledoc """
  Fetches a page from this same site and returns it as readable text.

  An agent can already fetch a URL for itself, so the value here is not the
  fetch. It is that the page arrives stripped of navigation, scripts and markup,
  from the site's own server, and that the read is recorded against the same
  visit as everything else that agent has done here.
  """

  @behaviour PhoenixAnalytics.MCP.Tool

  @max_bytes 400_000

  @impl true
  def definition do
    %{
      "name" => "read_page",
      "title" => "Read a page on this site",
      "description" =>
        "Fetches one page from this site and returns its readable text, with markup, scripts " <>
          "and navigation removed. Takes a path such as `/pricing`, not a full URL. Use " <>
          "`list_pages` first if you do not know what paths exist.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "A path on this site, beginning with `/`."
          }
        },
        "required" => ["path"]
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
  def call(%{"path" => path}, ctx) when is_binary(path) do
    with {:ok, path} <- validate(path, ctx),
         {:ok, body, content_type} <- fetch(ctx.base_url <> path) do
      {:ok,
       %{
         "path" => path,
         "content_type" => content_type,
         "text" => to_text(body, content_type)
       }}
    end
  end

  def call(_arguments, _ctx), do: {:error, "read_page needs a `path`, such as `/pricing`."}

  defp validate(path, ctx) do
    cond do
      not String.starts_with?(path, "/") ->
        {:error, "`path` must begin with `/`. Give a path on this site, not a full URL."}

      String.starts_with?(path, "//") ->
        {:error, "`path` must be a path on this site."}

      # Reading the endpoint through itself would be a loop, and a cheap one to
      # start by accident.
      String.starts_with?(path, ctx.mount_path) ->
        {:error, "That is this tool server's own endpoint; there is no page there."}

      true ->
        {:ok, path}
    end
  end

  defp fetch(url) do
    request = {String.to_charlist(url), [{~c"accept", ~c"text/html,text/plain,text/markdown"}]}

    case :httpc.request(:get, request, [timeout: 10_000, autoredirect: true],
           body_format: :binary
         ) do
      {:ok, {{_v, status, _r}, headers, body}} when status in 200..299 ->
        {:ok, binary_part(body, 0, min(byte_size(body), @max_bytes)), content_type(headers)}

      {:ok, {{_v, 404, _r}, _headers, _body}} ->
        {:error, "No page at that path."}

      {:ok, {{_v, status, _r}, _headers, _body}} ->
        {:error, "That page answered #{status}."}

      {:error, reason} ->
        {:error, "Could not read that page: #{inspect(reason)}"}
    end
  end

  defp content_type(headers) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if to_string(name) |> String.downcase() == "content-type", do: to_string(value)
    end)
    |> case do
      nil -> "application/octet-stream"
      type -> type |> String.split(";") |> hd() |> String.trim()
    end
  end

  defp to_text(body, "text/html" <> _), do: strip_html(body)
  defp to_text(body, _), do: String.trim(body)

  # Not a parser, and not trying to be. Script and style contents are removed
  # entirely because they are not prose; block-level tags become line breaks so
  # the shape of the page survives; everything else goes.
  defp strip_html(html) do
    html
    |> String.replace(~r{<(script|style|noscript|svg)\b[^>]*>.*?</\1>}is, " ")
    |> String.replace(~r{<!--.*?-->}s, " ")
    |> String.replace(~r{</(p|div|section|article|li|tr|h[1-6]|blockquote)>}i, "\n")
    |> String.replace(~r{<(br|hr)\s*/?>}i, "\n")
    |> String.replace(~r{<[^>]+>}, " ")
    |> decode_entities()
    |> String.replace(~r/[ \t\x{00A0}]+/u, " ")
    |> String.replace(~r{\n\s*\n\s*\n+}, "\n\n")
    |> String.trim()
  end

  defp decode_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&mdash;", "—")
    |> String.replace("&ndash;", "–")
  end
end
