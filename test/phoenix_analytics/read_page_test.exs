defmodule PhoenixAnalytics.ReadPageTest do
  @moduledoc """
  `read_page` against a real server, because the value of the tool is entirely
  in what comes back: a page an agent can read, not a page of markup.
  """

  use ExUnit.Case, async: false

  alias PhoenixAnalytics.MCP.Tools.ReadPage

  @html """
  <!DOCTYPE html>
  <html>
    <head>
      <title>Pricing</title>
      <style>.nav { color: red }</style>
      <script>window.analytics = {track: function(){}}</script>
    </head>
    <body>
      <nav><a href="/">Home</a> <a href="/docs">Docs</a></nav>
      <h1>Pricing</h1>
      <p>Free while you&#39;re small &amp; fair when you grow.</p>
      <ul><li>Unlimited events</li><li>No card required</li></ul>
      <script>console.log("tracking")</script>
    </body>
  </html>
  """

  setup do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server = spawn_link(fn -> serve(listen) end)

    on_exit(fn ->
      :gen_tcp.close(listen)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    {:ok, ctx: %{base_url: "http://127.0.0.1:#{port}", mount_path: "/mcp"}}
  end

  test "returns the prose and leaves the machinery behind", %{ctx: ctx} do
    assert {:ok, page} = ReadPage.call(%{"path" => "/pricing"}, ctx)

    assert page["path"] == "/pricing"
    assert page["content_type"] == "text/html"

    text = page["text"]

    assert text =~ "Pricing"
    assert text =~ "Unlimited events"

    # The parts of a page that are not for reading.
    refute text =~ "console.log"
    refute text =~ "color: red"
    refute text =~ "<h1>"
    refute text =~ "window.analytics"
  end

  test "decodes the entities a reader would otherwise see raw", %{ctx: ctx} do
    {:ok, page} = ReadPage.call(%{"path" => "/pricing"}, ctx)

    assert page["text"] =~ "you're small & fair"
    refute page["text"] =~ "&amp;"
    refute page["text"] =~ "&#39;"
  end

  test "keeps the shape of the page rather than running it together", %{ctx: ctx} do
    {:ok, page} = ReadPage.call(%{"path" => "/pricing"}, ctx)

    # Block elements become line breaks; without that a list reads as one
    # sentence and a model has to guess where items end.
    assert page["text"] =~ ~r/Unlimited events\s*\n\s*No card required/
  end

  test "a missing page says so in words a model can act on", %{ctx: ctx} do
    assert {:error, message} = ReadPage.call(%{"path" => "/nope"}, ctx)
    assert message =~ "No page at that path"
  end

  defp serve(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        respond(socket, data)
        :gen_tcp.close(socket)
        serve(listen)

      {:error, _} ->
        :ok
    end
  end

  defp respond(socket, request) do
    body = if String.contains?(request, "/pricing"), do: @html, else: "not here"
    status = if String.contains?(request, "/pricing"), do: "200 OK", else: "404 Not Found"

    :gen_tcp.send(socket, """
    HTTP/1.1 #{status}\r
    content-type: text/html; charset=utf-8\r
    content-length: #{byte_size(body)}\r
    connection: close\r
    \r
    #{body}\
    """)
  end
end
