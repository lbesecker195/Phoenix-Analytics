defmodule PhoenixAnalytics.ConnCase do
  @moduledoc "Helpers for driving the plug the way a server would."

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Test
      import Plug.Conn
      import PhoenixAnalytics.ConnCase
    end
  end

  setup do
    Application.put_env(:phoenix_analytics_middleware, :test_pid, self())
    on_exit(fn -> Application.delete_env(:phoenix_analytics_middleware, :test_pid) end)
    :ok
  end

  @doc "Default plug options pointed at the capturing transport."
  def opts(extra \\ []) do
    PhoenixAnalytics.Plug.init(
      Keyword.merge(
        [
          site: "test-site",
          endpoint: "https://example.test/api/v1/collect",
          transport: PhoenixAnalytics.TestTransport
        ],
        extra
      )
    )
  end

  @doc """
  Runs one request through the plug and returns the connection.

  `cookies` are the request cookies the client sends; `html?` controls whether
  the response looks like a document.
  """
  def request(path, cookies \\ %{}, plug_opts \\ opts(), overrides \\ []) do
    conn =
      Plug.Test.conn(Keyword.get(overrides, :method, "GET"), path)
      |> put_cookies(cookies)
      |> put_headers(Keyword.get(overrides, :headers, []))
      |> Map.put(:host, Keyword.get(overrides, :host, "www.example.com"))

    conn
    |> PhoenixAnalytics.Plug.call(plug_opts)
    |> respond(overrides)
  end

  defp respond(conn, overrides) do
    status = Keyword.get(overrides, :status, 200)
    content_type = Keyword.get(overrides, :content_type, "text/html; charset=utf-8")

    conn
    |> then(fn c ->
      if content_type,
        do: Plug.Conn.put_resp_content_type(c, strip_charset(content_type)),
        else: c
    end)
    |> Plug.Conn.send_resp(status, "<html></html>")
  end

  defp strip_charset(type), do: type |> String.split(";") |> List.first() |> String.trim()

  defp put_cookies(conn, cookies) when map_size(cookies) == 0, do: conn

  defp put_cookies(conn, cookies) do
    header = Enum.map_join(cookies, "; ", fn {k, v} -> "#{k}=#{v}" end)
    Plug.Conn.put_req_header(conn, "cookie", header)
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
  end

  @doc "The cookies a response sets, as a plain map of name to value."
  def resp_cookies(conn) do
    Map.new(conn.resp_cookies, fn {name, %{value: value}} -> {name, value} end)
  end

  @doc "Waits for the reporter and returns the single beacon it delivered."
  def captured_beacon do
    PhoenixAnalytics.Reporter.flush()

    receive do
      {:beacon, payload, request} -> {payload, request}
    after
      500 -> flunk("no beacon was delivered")
    end
  end

  @doc "Asserts nothing was delivered."
  def refute_beacon do
    PhoenixAnalytics.Reporter.flush()

    receive do
      {:beacon, payload, _request} -> flunk("unexpected beacon: #{inspect(payload)}")
    after
      50 -> :ok
    end
  end

  @doc "The pageview event inside a beacon."
  def pageview(payload), do: Enum.find(payload["e"], &(&1["n"] == "pv"))

  @doc "The init event inside a beacon, if it sent one."
  def init_event(payload), do: Enum.find(payload["e"], &(&1["n"] == "init"))
end
