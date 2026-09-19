defmodule PhoenixAnalytics.Transport.HTTP do
  @moduledoc """
  Posts the beacon with `:httpc`.

  `:httpc` rather than a client library because this is installed into other
  people's applications, where every dependency is one they did not ask for and
  may already have a conflicting version of. It ships with Erlang.

  ## Passing the visitor through

  The endpoint reads the address and CDN geolocation headers of the request that
  carries the beacon. That request originates here, on the server, so left alone
  every visitor would resolve to the data centre. The visitor's address is
  forwarded as `x-forwarded-for` and their CDN headers are copied verbatim, which
  puts the endpoint back in the position the browser tag would have put it in.

  The endpoint decides for itself whether to believe `x-forwarded-for`: it only
  does so when that deployment is configured to sit behind a proxy
  (`SSA_TRUST_PROXY`). Without it the visit still records, geolocated to this
  application's own address.
  """

  @behaviour PhoenixAnalytics.Transport

  alias PhoenixAnalytics.Config
  alias PhoenixAnalytics.Request

  @impl true
  def deliver(payload, %Request{} = request, %Config{} = config) do
    body = Jason.encode!(payload)
    url = String.to_charlist(config.endpoint)

    headers = headers(request, config)

    http_opts = [
      timeout: config.timeout_ms,
      connect_timeout: config.timeout_ms,
      # The endpoint answers 204 with nothing to follow, and a redirect chased
      # automatically would re-post the beacon somewhere unintended.
      autoredirect: false
    ]

    request_tuple = {url, headers, ~c"application/json", body}

    case :httpc.request(:post, request_tuple, http_opts, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, _body}} when status in 200..299 ->
        :ok

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The headers that carry the visitor's identity to the endpoint.

  Public because this, not the POST itself, is the part worth asserting on.
  """
  def headers(%Request{} = request, %Config{} = config) do
    [{~c"content-type", ~c"application/json"}]
    |> put_client_ip(request, config)
    |> put_geo(request)
  end

  defp put_client_ip(headers, _request, %Config{forward_client_ip: false}), do: headers
  defp put_client_ip(headers, %Request{client_ip: nil}, _config), do: headers

  defp put_client_ip(headers, %Request{client_ip: ip}, _config),
    do: [{~c"x-forwarded-for", String.to_charlist(ip)} | headers]

  defp put_geo(headers, %Request{geo_headers: geo}) when is_list(geo) do
    Enum.reduce(geo, headers, fn {name, value}, acc ->
      [{String.to_charlist(name), String.to_charlist(value)} | acc]
    end)
  end

  defp put_geo(headers, _request), do: headers
end
