defmodule Mix.Tasks.PhoenixAnalytics.ServerJson do
  @shortdoc "Writes the server.json that lists this site as an MCP server"

  @moduledoc """
  Generates the descriptor an MCP registry needs to list this application.

      mix phoenix_analytics.server_json --url https://example.com --name com.example/my-site

  Mounting `PhoenixAnalytics.MCP.Plug` makes a site callable. It does not make
  it *findable* — an agent has to be told the server exists, and registries are
  how. This writes the file they read.

  ## Why generate it rather than write it by hand

  The two things people get wrong are both mechanical. `remotes[].url` is the
  mount path, not the site root, and a registry that is handed the root will
  list a server that answers nothing. And `name` is reverse-DNS, derived from a
  domain the publisher controls, which is what stops two people claiming the
  same identity.

  Pass `--verify` and the endpoint is called before anything is written, so a
  descriptor is never published pointing at a server that is not there.

  ## Options

    * `--url` — the site's base URL. Required.
    * `--name` — reverse-DNS identity, e.g. `com.example/my-site`. Derived from
      the URL's host when omitted.
    * `--mount` — where the plug is forwarded. Defaults to `/mcp`.
    * `--title` — a human name for the server.
    * `--description` — one sentence. Registries show this; it is what decides
      whether an agent tries the server at all.
    * `--repository` — a source URL, if the server is open.
    * `--version` — defaults to `1.0.0`.
    * `--output` — file to write. Defaults to `server.json`; `-` prints instead.
    * `--verify` — call the endpoint first and refuse to write if it is silent.
  """

  use Mix.Task

  @schema "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json"
  @switches [
    url: :string,
    name: :string,
    mount: :string,
    title: :string,
    description: :string,
    repository: :string,
    version: :string,
    output: :string,
    verify: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: @switches)

    url = opts |> Keyword.get(:url) |> require_url()
    mount = opts |> Keyword.get(:mount, "/mcp") |> normalise_mount()
    endpoint = String.trim_trailing(url, "/") <> mount

    if opts[:verify], do: verify!(endpoint)

    descriptor = descriptor(opts, url, endpoint)
    json = Jason.encode!(descriptor, pretty: true) <> "\n"

    case Keyword.get(opts, :output, "server.json") do
      "-" -> Mix.shell().info(json)
      path -> write(path, json, endpoint)
    end
  end

  defp descriptor(opts, url, endpoint) do
    %{
      "$schema" => @schema,
      "name" => opts[:name] || derive_name(url),
      "description" => opts[:description] || "MCP server for #{host(url)}.",
      "version" => opts[:version] || "1.0.0",
      "websiteUrl" => url,
      "remotes" => [%{"type" => "streamable-http", "url" => endpoint}]
    }
    |> put_unless_nil("title", opts[:title])
    |> put_repository(opts[:repository])
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp put_repository(map, nil), do: map

  defp put_repository(map, url) do
    source = if String.contains?(url, "github.com"), do: "github", else: "git"
    Map.put(map, "repository", %{"url" => url, "source" => source})
  end

  # Reverse-DNS from the host, which is the convention and also the only part a
  # publisher can prove they control.
  defp derive_name(url) do
    host = url |> host() |> String.replace_prefix("www.", "")
    labels = host |> String.split(".") |> Enum.reverse()

    case labels do
      [tld, domain | rest] ->
        slug = if rest == [], do: domain, else: Enum.join(Enum.reverse(rest), "-")
        "#{tld}.#{domain}/#{slug}"

      _ ->
        "local.#{host}/server"
    end
  end

  defp host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> url
    end
  end

  defp require_url(nil) do
    Mix.raise("""
    --url is required.

        mix phoenix_analytics.server_json --url https://example.com
    """)
  end

  defp require_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        url

      _ ->
        Mix.raise("--url must be an absolute URL, such as https://example.com")
    end
  end

  defp normalise_mount(mount) do
    mount = if String.starts_with?(mount, "/"), do: mount, else: "/" <> mount
    String.trim_trailing(mount, "/")
  end

  # A listing that points at nothing is worse than no listing: an agent spends a
  # call finding out, and the registry keeps offering it.
  defp verify!(endpoint) do
    Mix.shell().info("Calling #{endpoint} ...")

    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
    request = {String.to_charlist(endpoint), [], ~c"application/json", body}

    case :httpc.request(:post, request, [timeout: 10_000], body_format: :binary) do
      {:ok, {{_v, status, _r}, _headers, response}} when status in 200..299 ->
        report(response)

      {:ok, {{_v, status, _r}, _headers, _response}} ->
        Mix.raise("#{endpoint} answered #{status}. Is the plug mounted there?")

      {:error, reason} ->
        Mix.raise("Could not reach #{endpoint}: #{inspect(reason)}")
    end
  end

  defp report(response) do
    case Jason.decode(response) do
      {:ok, %{"result" => %{"tools" => tools}}} ->
        Mix.shell().info("  #{length(tools)} tools: #{Enum.map_join(tools, ", ", & &1["name"])}")

      {:ok, %{"error" => %{"message" => message}}} ->
        Mix.raise("That endpoint answered with an error: #{message}")

      _ ->
        Mix.raise("That endpoint did not answer like an MCP server.")
    end
  end

  defp write(path, json, endpoint) do
    File.write!(path, json)

    Mix.shell().info("""
    Wrote #{path}

    It describes the server at #{endpoint}.
    Publish it to a registry to let agents find it — https://ai.mcpharbor.dev
    lists MCP servers and takes this file as-is.
    """)
  end
end
