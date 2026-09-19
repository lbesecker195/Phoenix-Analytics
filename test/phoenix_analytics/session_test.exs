defmodule PhoenixAnalytics.SessionTest do
  use ExUnit.Case, async: true

  alias PhoenixAnalytics.Session

  describe "registrable_domain/1" do
    test "keeps a visit together across subdomains" do
      assert Session.registrable_domain("www.example.com") == "example.com"
      assert Session.registrable_domain("blog.shop.example.com") == "example.com"
      assert Session.registrable_domain("example.com") == "example.com"
    end

    test "handles compound public suffixes" do
      assert Session.registrable_domain("www.example.co.uk") == "example.co.uk"
      assert Session.registrable_domain("example.com.au") == "example.com.au"
    end

    test "falls back to a host-only cookie where a domain one cannot work" do
      # A browser refuses a domain cookie on an address or a bare host, and a
      # refused cookie means a visit that splits on every request.
      assert Session.registrable_domain("localhost") == nil
      assert Session.registrable_domain("127.0.0.1") == nil
      assert Session.registrable_domain(nil) == nil
    end
  end

  describe "reading the session cookie" do
    test "continues an existing visit" do
      session = resolve(%{"wa_sid" => "abc.3", "wa_srv" => "3|/docs", "wa_vid" => "vis-1"})

      assert session.token == "abc"
      assert session.visitor == "vis-1"
      assert session.new? == false
      assert session.seq == 4
    end

    test "mints a visit when there is none" do
      session = resolve(%{})

      assert session.new?
      assert session.seq == 1
      assert session.token =~ ~r/^[0-9a-f-]{36}$/
      assert session.visitor =~ ~r/^[0-9a-f-]{36}$/
    end

    test "remembers the page it last recorded" do
      session = resolve(%{"wa_srv" => "4|/pricing"})

      assert session.seq == 5
      assert session.last_path == "/pricing"
    end

    test "takes the higher of the two counters" do
      # The tag's counter leads while it is running; the plug's leads when it is
      # not. Whichever is ahead is the one that reflects pages already recorded.
      assert resolve(%{"wa_sid" => "abc.7", "wa_srv" => "2|/a"}).seq == 8
      assert resolve(%{"wa_sid" => "abc.0", "wa_srv" => "5|/a"}).seq == 6
    end

    test "survives a malformed cookie rather than dropping the request" do
      # These arrive from the client, so every one of them is reachable by
      # anyone who cares to try.
      assert resolve(%{"wa_sid" => "abc"}).seq == 1
      assert resolve(%{"wa_sid" => "abc.not-a-number"}).seq == 1
      assert resolve(%{"wa_sid" => "abc.-4"}).seq == 1
      assert resolve(%{"wa_sid" => ""}).new? == true
      assert resolve(%{"wa_sid" => "abc.3", "wa_srv" => "garbage"}).seq == 4
      assert resolve(%{"wa_srv" => "2|"}).last_path == nil
    end

    test "keeps a returning visitor's id across sessions" do
      assert resolve(%{"wa_vid" => "vis-9"}).visitor == "vis-9"
    end
  end

  describe "writing cookies" do
    test "leaves the tag's counter exactly as it was found" do
      cookies = write(%{"wa_sid" => "abc.4", "wa_srv" => "4"})

      # Advancing this would make the tag skip a number and split the page it is
      # about to open into a row of its own.
      assert cookies["wa_sid"].value == "abc.4"
      assert cookies["wa_srv"].value == "5|/"
    end

    test "opens a new visit on zero so the tag's first page is page one" do
      cookies = write(%{})

      assert cookies["wa_sid"].value =~ ~r/\.0$/
      assert cookies["wa_srv"].value == "1|/"
    end

    test "scopes cookies the way the tag does" do
      cookies = write(%{}, "www.example.com")
      sid = cookies["wa_sid"]

      assert sid.domain == ".example.com"
      assert sid.path == "/"
      assert sid.same_site == "Lax"
      # Readable by the tag, which has to seed from it.
      assert sid.http_only == false
    end

    test "honours an explicit cookie domain" do
      cookies = write(%{}, "www.example.co.uk", cookie_domain: "example.co.uk")
      assert cookies["wa_sid"].domain == ".example.co.uk"
    end

    test "outlives the visit for the visitor cookie only" do
      cookies = write(%{})

      assert cookies["wa_sid"].max_age == 30 * 60
      assert cookies["wa_vid"].max_age == 60 * 60 * 24 * 365
    end
  end

  defp resolve(cookies) do
    conn(cookies) |> Session.resolve()
  end

  defp write(cookies, host \\ "www.example.com", config_opts \\ []) do
    conn = conn(cookies) |> Map.put(:host, host)
    config = PhoenixAnalytics.Config.build(config_opts)

    conn
    |> Session.put_cookies(Session.resolve(conn), config)
    |> Map.fetch!(:resp_cookies)
  end

  defp conn(cookies) do
    header = Enum.map_join(cookies, "; ", fn {k, v} -> "#{k}=#{v}" end)

    :get
    |> Plug.Test.conn("/")
    |> then(fn c ->
      if header == "", do: c, else: Plug.Conn.put_req_header(c, "cookie", header)
    end)
    |> Plug.Conn.fetch_cookies()
  end
end
