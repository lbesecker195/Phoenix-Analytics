defmodule PhoenixAnalytics.TransportHTTPTest do
  @moduledoc """
  The default transport against a real socket.

  Everything else in this suite swaps the transport out, which leaves the one
  piece that actually talks to the network unexercised. This runs it for real:
  a listener accepts the POST, and the test asserts on the bytes that arrived.
  """

  use ExUnit.Case, async: false

  alias PhoenixAnalytics.Config
  alias PhoenixAnalytics.Request
  alias PhoenixAnalytics.Transport.HTTP

  setup do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test = self()

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        send(test, {:received, read_request(socket)})
        :gen_tcp.send(socket, "HTTP/1.1 204 No Content\r\ncontent-length: 0\r\n\r\n")
        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listen)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    {:ok, port: port}
  end

  test "posts the beacon as JSON with the visitor's identity attached", %{port: port} do
    config =
      Config.build(
        site: "site-key",
        endpoint: "http://127.0.0.1:#{port}/api/v1/collect"
      )

    request = %Request{
      path: "/pricing",
      client_ip: "203.0.113.42",
      geo_headers: [{"cf-ipcountry", "DE"}],
      duration_ms: 12
    }

    payload = %{"k" => "site-key", "s" => "tok", "v" => "vis", "t" => 1, "e" => []}

    assert :ok = HTTP.deliver(payload, request, config)

    assert_receive {:received, raw}, 2_000

    [headers, body] = String.split(raw, "\r\n\r\n", parts: 2)
    lowered = String.downcase(headers)

    assert lowered =~ "post /api/v1/collect"
    assert lowered =~ "content-type: application/json"

    # Without these the endpoint geolocates this application's own server
    # instead of the person who made the request.
    assert lowered =~ "x-forwarded-for: 203.0.113.42"
    assert lowered =~ "cf-ipcountry: de"

    assert Jason.decode!(body) == payload
  end

  test "reports a refused connection instead of raising", %{port: port} do
    # Whatever happens here is swallowed by the reporter, but it has to come
    # back as a value for the failure to be counted rather than crash a task.
    config = Config.build(site: "k", endpoint: "http://127.0.0.1:#{port + 1}/collect")

    assert {:error, _reason} =
             HTTP.deliver(%{"k" => "k"}, %Request{geo_headers: []}, config)
  end

  # Reads until the body named by content-length has arrived.
  defp read_request(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} ->
        acc = acc <> chunk

        if complete?(acc), do: acc, else: read_request(socket, acc)

      {:error, _} ->
        acc
    end
  end

  defp complete?(raw) do
    case String.split(raw, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
          [_, length] -> byte_size(body) >= String.to_integer(length)
          nil -> true
        end

      _ ->
        false
    end
  end
end
