defmodule PhoenixAnalytics.ServerJsonTest do
  @moduledoc """
  The descriptor a registry reads to list a site.

  Two fields decide whether a listing works at all: `remotes[].url`, which has
  to be the mount path rather than the site root, and `name`, which has to be
  reverse-DNS from a domain the publisher controls. Both are checked here.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.PhoenixAnalytics.ServerJson

  setup do
    dir = Path.join(System.tmp_dir!(), "pam-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, out: Path.join(dir, "server.json")}
  end

  defp generate(args) do
    capture_io(fn -> ServerJson.run(args) end)
  end

  defp descriptor(args, out) do
    generate(args ++ ["--output", out])
    out |> File.read!() |> Jason.decode!()
  end

  describe "the endpoint it advertises" do
    test "points at the mount path, not the site root", %{out: out} do
      json = descriptor(["--url", "https://example.com"], out)

      assert [%{"type" => "streamable-http", "url" => url}] = json["remotes"]
      assert url == "https://example.com/mcp"
      assert json["websiteUrl"] == "https://example.com"
    end

    test "follows a mount somewhere else", %{out: out} do
      json = descriptor(["--url", "https://example.com", "--mount", "tools/mcp"], out)

      assert [%{"url" => "https://example.com/tools/mcp"}] = json["remotes"]
    end

    test "does not double a slash when the site URL has a trailing one", %{out: out} do
      json = descriptor(["--url", "https://example.com/", "--mount", "/mcp/"], out)

      assert [%{"url" => "https://example.com/mcp"}] = json["remotes"]
    end
  end

  describe "identity" do
    test "is derived reverse-DNS from the host" do
      out = Path.join(System.tmp_dir!(), "a-#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(out) end)

      assert descriptor(["--url", "https://mcpharbor.com"], out)["name"] ==
               "com.mcpharbor/mcpharbor"
    end

    test "uses the subdomain as the server's own name", %{out: out} do
      json = descriptor(["--url", "https://ai.mcpharbor.com"], out)

      assert json["name"] == "com.mcpharbor/ai"
    end

    test "ignores www, which identifies nothing", %{out: out} do
      json = descriptor(["--url", "https://www.example.com"], out)

      assert json["name"] == "com.example/example"
    end

    test "an explicit name wins", %{out: out} do
      json = descriptor(["--url", "https://example.com", "--name", "com.example/registry"], out)

      assert json["name"] == "com.example/registry"
    end
  end

  describe "the rest of the descriptor" do
    test "carries the schema and a usable default description", %{out: out} do
      json = descriptor(["--url", "https://example.com"], out)

      assert json["$schema"] =~ "server.schema.json"
      assert json["version"] == "1.0.0"
      assert json["description"] =~ "example.com"
    end

    test "takes a title, description, version and repository", %{out: out} do
      json =
        descriptor(
          [
            "--url",
            "https://example.com",
            "--title",
            "My Site",
            "--description",
            "Search the catalogue.",
            "--version",
            "2.1.0",
            "--repository",
            "https://github.com/someone/thing"
          ],
          out
        )

      assert json["title"] == "My Site"
      assert json["description"] == "Search the catalogue."
      assert json["version"] == "2.1.0"

      assert json["repository"] == %{
               "url" => "https://github.com/someone/thing",
               "source" => "github"
             }
    end

    test "leaves out what it was not given", %{out: out} do
      json = descriptor(["--url", "https://example.com"], out)

      refute Map.has_key?(json, "title")
      refute Map.has_key?(json, "repository")
    end

    test "prints instead of writing when asked" do
      output = generate(["--url", "https://example.com", "--output", "-"])

      assert Jason.decode!(output)["websiteUrl"] == "https://example.com"
    end
  end

  describe "refusing to produce something broken" do
    test "a missing URL explains itself" do
      assert_raise Mix.Error, ~r/--url is required/, fn ->
        capture_io(fn -> ServerJson.run([]) end)
      end
    end

    test "a relative URL is refused" do
      assert_raise Mix.Error, ~r/absolute URL/, fn ->
        capture_io(fn -> ServerJson.run(["--url", "example.com"]) end)
      end
    end
  end

  describe "--verify" do
    setup do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      {:ok, listen: listen, port: port}
    end

    test "refuses to write when the endpoint is not there", %{
      listen: listen,
      port: port,
      out: out
    } do
      :gen_tcp.close(listen)

      assert_raise Mix.Error, ~r/Could not reach/, fn ->
        capture_io(fn ->
          ServerJson.run(["--url", "http://127.0.0.1:#{port}", "--verify", "--output", out])
        end)
      end

      refute File.exists?(out), "a descriptor was written for a server that is not running"
    end

    test "reports the tools when the endpoint answers", %{listen: listen, out: out} do
      {:ok, port} = :inet.port(listen)
      serve(listen, ~s({"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"list_pages"}]}}))

      output =
        capture_io(fn ->
          ServerJson.run(["--url", "http://127.0.0.1:#{port}", "--verify", "--output", out])
        end)

      assert output =~ "1 tools: list_pages"
      assert File.exists?(out)
    end
  end

  defp serve(listen, body) do
    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

      :gen_tcp.send(socket, """
      HTTP/1.1 200 OK\r
      content-type: application/json\r
      content-length: #{byte_size(body)}\r
      connection: close\r
      \r
      #{body}\
      """)

      :gen_tcp.close(socket)
    end)
  end
end
