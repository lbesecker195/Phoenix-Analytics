defmodule PhoenixAnalytics.Request do
  @moduledoc """
  What a server can observe about one request, and whether it is worth recording.

  ## What counts as a pageview

  A plug sees everything: stylesheets, favicons, health checks, XHR, websocket
  upgrades. Recording all of it would not just add noise, it would break the
  sequence this library shares with the browser tag — every asset would claim a
  pageview number the tag was going to use for a real page.

  So a request is recorded only when it looks like a document being fetched, and
  the test differs by client on purpose:

    * **Browsers** send `sec-fetch-dest`, which says what the response is for.
      When that header is present it is believed absolutely: `document` is a
      navigation, everything else is a subresource or a background fetch. This is
      what keeps the plug in step with the tag, because `document` is exactly
      when the tag opens a pageview too.

    * **Everything else** — agents, crawlers, scripts, anything built on an HTTP
      library — sends no such header, and is judged on what it received instead:
      a successful GET of something readable. An agent reading `llms.txt` or a
      JSON endpoint is doing the thing this library exists to see, and no
      browser-shaped test would count it.
  """

  alias PhoenixAnalytics.Payload

  defstruct [
    :path,
    :url,
    :host,
    :protocol,
    :port,
    :query,
    :referrer,
    :referrer_path,
    :user_agent,
    :language,
    :client_ip,
    :geo_headers,
    :duration_ms,
    utm: %{}
  ]

  @type t :: %__MODULE__{}

  # Read by the collect endpoint to place a visitor without a lookup. Forwarded
  # verbatim so a visit through a CDN resolves to the visitor's city rather than
  # to wherever this application happens to run.
  @geo_headers ~w(
    cf-ipcountry cf-ipcity cf-region cf-region-code cf-iplatitude cf-iplongitude
    x-vercel-ip-country x-vercel-ip-country-region x-vercel-ip-city
    x-vercel-ip-latitude x-vercel-ip-longitude
    cloudfront-viewer-country cloudfront-viewer-country-name
    cloudfront-viewer-country-region cloudfront-viewer-country-region-name
    cloudfront-viewer-city cloudfront-viewer-latitude cloudfront-viewer-longitude
    x-nf-geo x-geo-country x-geo-region x-geo-region-code x-geo-city
    x-geo-latitude x-geo-longitude
  )

  @readable ~w(text/html text/plain text/markdown application/json application/xml text/xml)

  @doc "Whether this response should be recorded as a pageview."
  def trackable?(conn, ignore_paths) do
    conn.method in ["GET", "HEAD"] and
      conn.status in 200..299 and
      not ignored?(conn.request_path, ignore_paths) and
      destination_ok?(conn)
  end

  defp destination_ok?(conn) do
    case Plug.Conn.get_req_header(conn, "sec-fetch-dest") do
      [dest | _] -> dest == "document"
      [] -> readable?(conn)
    end
  end

  defp readable?(conn) do
    case Plug.Conn.get_resp_header(conn, "content-type") do
      [type | _] -> Enum.any?(@readable, &String.starts_with?(type, &1))
      [] -> false
    end
  end

  defp ignored?(_path, []), do: false

  defp ignored?(path, patterns) do
    Enum.any?(patterns, fn
      %Regex{} = regex -> Regex.match?(regex, path)
      prefix when is_binary(prefix) -> String.starts_with?(path, prefix)
      fun when is_function(fun, 1) -> fun.(path)
      _ -> false
    end)
  end

  @doc "Extracts everything reportable from the connection."
  def extract(conn, duration_ms) do
    query = if conn.query_string in [nil, ""], do: nil, else: conn.query_string

    %__MODULE__{
      path: conn.request_path,
      url: url(conn),
      host: conn.host,
      protocol: to_string(conn.scheme),
      port: conn.port,
      query: query,
      referrer: header(conn, "referer"),
      referrer_path: referrer_path(header(conn, "referer"), conn.host),
      user_agent: header(conn, "user-agent"),
      language: language(conn),
      client_ip: client_ip(conn),
      geo_headers: geo_headers(conn),
      duration_ms: duration_ms,
      utm: utm(conn)
    }
  end

  # The page a visit came from, when it came from this same site. A referrer
  # pointing somewhere else is where the visit started, not a step within it, and
  # treating it as one would draw edges into the flow graph from other people's
  # websites.
  defp referrer_path(nil, _host), do: nil

  defp referrer_path(referrer, host) do
    case URI.parse(referrer) do
      %URI{host: ^host, path: path} when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp url(conn) do
    base = "#{conn.scheme}://#{conn.host}#{port_suffix(conn)}#{conn.request_path}"
    if conn.query_string in [nil, ""], do: base, else: base <> "?" <> conn.query_string
  end

  defp port_suffix(%{scheme: :http, port: 80}), do: ""
  defp port_suffix(%{scheme: :https, port: 443}), do: ""
  defp port_suffix(%{port: port}) when is_integer(port), do: ":#{port}"
  defp port_suffix(_), do: ""

  defp utm(conn) do
    case conn.query_string do
      empty when empty in [nil, ""] -> %{}
      query -> query |> URI.decode_query() |> Payload.utm()
    end
  end

  # Only the first tag, and only its language: the endpoint stores one value,
  # and quality weights are not part of it.
  defp language(conn) do
    case header(conn, "accept-language") do
      nil ->
        nil

      value ->
        value
        |> String.split(",")
        |> List.first()
        |> String.split(";")
        |> List.first()
        |> String.trim()
        |> case do
          "" -> nil
          lang -> lang
        end
    end
  end

  @doc """
  The address this request came from.

  `x-forwarded-for` wins when present because an application behind a proxy sees
  only the proxy's address on the socket. The value is passed along rather than
  trusted here — the collect endpoint applies its own proxy policy before
  anything is stored.
  """
  def client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
      [] -> remote_ip(conn)
    end
  end

  defp remote_ip(%Plug.Conn{remote_ip: nil}), do: nil
  defp remote_ip(%Plug.Conn{remote_ip: ip}), do: ip |> :inet.ntoa() |> to_string()

  defp geo_headers(conn) do
    for name <- @geo_headers,
        [value | _] <- [Plug.Conn.get_req_header(conn, name)],
        do: {name, value}
  end

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] when value != "" -> value
      _ -> nil
    end
  end
end
