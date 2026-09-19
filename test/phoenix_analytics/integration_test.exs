defmodule PhoenixAnalytics.IntegrationTest do
  @moduledoc """
  The claim this library lives or dies on: a server and a browser tag, looking at
  the same cookie, number the same page the same way.

  These walk whole visits rather than single calls, because the failure being
  guarded against is drift — two halves that agree on the first page and slide
  apart by the third.
  """

  use PhoenixAnalytics.ConnCase, async: false

  alias PhoenixAnalytics.TagSimulator

  describe "a visit with the browser tag installed" do
    test "the plug and the tag choose the same sequence number for every page" do
      # --- first page ------------------------------------------------------
      # Nothing in the browser yet: this is the request that opens the session.
      conn = request("/")
      {payload, _request} = captured_beacon()
      cookies = resp_cookies(conn)

      server_seq = pageview(payload)["seq"]
      assert server_seq == 1

      # The tag now loads into that same document and seeds from the cookie the
      # response carried.
      tag = TagSimulator.new_document(cookies)
      {tag, tag_seq} = TagSimulator.open_pageview(tag)

      assert tag_seq == server_seq,
             "the tag numbered the landing page #{tag_seq}, the server #{server_seq}"

      assert tag.token == String.split(cookies["wa_sid"], ".") |> hd(),
             "the tag adopted a different session token than the plug minted"

      # --- second page -----------------------------------------------------
      # The tag has persisted its counter; the browser sends it back.
      browser_cookies = %{
        "wa_sid" => TagSimulator.cookie(tag),
        "wa_srv" => cookies["wa_srv"],
        "wa_vid" => cookies["wa_vid"]
      }

      conn = request("/pricing", browser_cookies)
      {payload, _request} = captured_beacon()

      server_seq = pageview(payload)["seq"]
      {tag, tag_seq} = TagSimulator.open_pageview(TagSimulator.new_document(browser_cookies))

      assert server_seq == 2
      assert tag_seq == server_seq, "drifted on the second page: #{tag_seq} vs #{server_seq}"

      # --- third page ------------------------------------------------------
      browser_cookies = %{
        "wa_sid" => TagSimulator.cookie(tag),
        "wa_srv" => resp_cookies(conn)["wa_srv"],
        "wa_vid" => cookies["wa_vid"]
      }

      request("/docs", browser_cookies)
      {payload, _request} = captured_beacon()

      {_tag, tag_seq} = TagSimulator.open_pageview(TagSimulator.new_document(browser_cookies))

      assert pageview(payload)["seq"] == 3
      assert tag_seq == 3, "drifted on the third page"
    end

    test "the session token survives the whole visit" do
      conn = request("/")
      {first, _} = captured_beacon()
      cookies = resp_cookies(conn)

      tag = TagSimulator.new_document(cookies)
      {tag, _} = TagSimulator.open_pageview(tag)

      request("/pricing", %{
        "wa_sid" => TagSimulator.cookie(tag),
        "wa_srv" => cookies["wa_srv"],
        "wa_vid" => cookies["wa_vid"]
      })

      {second, _} = captured_beacon()

      assert first["s"] == second["s"], "the visit split into two sessions"
      assert first["v"] == second["v"], "the visitor changed mid-visit"
    end
  end

  describe "a visit with no JavaScript at all" do
    test "the plug sequences the visit by itself" do
      conn = request("/")
      {payload, _} = captured_beacon()
      assert pageview(payload)["seq"] == 1

      # The tag never runs, so `wa_sid` keeps the zero the plug wrote and the
      # numbering has to come from the plug's own cookie.
      cookies = carry(resp_cookies(conn))
      assert cookies["wa_sid"] =~ ~r/\.0$/

      conn = request("/about", cookies)
      {payload, _} = captured_beacon()
      assert pageview(payload)["seq"] == 2

      request("/contact", carry(resp_cookies(conn)))
      {payload, _} = captured_beacon()
      assert pageview(payload)["seq"] == 3
    end

    test "one session covers the whole visit" do
      conn = request("/")
      {first, _} = captured_beacon()

      request("/about", carry(resp_cookies(conn)))
      {second, _} = captured_beacon()

      assert first["s"] == second["s"]
    end
  end

  describe "page flow" do
    test "a visit is chained into a path through the site" do
      # Without this every page looks like a landing page and the flow report is
      # empty: the endpoint only chains pages together for callers that let it
      # assign the numbers, and this one assigns its own.
      conn = request("/")
      {payload, _} = captured_beacon()
      refute pageview(payload)["fp"], "the first page came from nowhere"

      conn = request("/pricing", carry(resp_cookies(conn)))
      {payload, _} = captured_beacon()
      assert pageview(payload)["fp"] == "/"

      request("/docs", carry(resp_cookies(conn)))
      {payload, _} = captured_beacon()
      assert pageview(payload)["fp"] == "/pricing"
    end

    test "a same-site referrer is preferred over what the plug last saw" do
      # The browser is reporting an actual navigation, which beats the plug's
      # guess when a visitor has two tabs open on the same site.
      conn = request("/")
      captured_beacon()

      request("/docs", carry(resp_cookies(conn)), opts(),
        headers: [{"referer", "http://www.example.com/blog/post"}]
      )

      {payload, _} = captured_beacon()
      assert pageview(payload)["fp"] == "/blog/post"
    end

    test "a referrer from another site does not become a step in the visit" do
      request("/", %{}, opts(), headers: [{"referer", "https://news.ycombinator.com/item?id=1"}])
      {payload, _} = captured_beacon()

      refute pageview(payload)["fp"],
             "an external referrer would draw a flow edge in from somebody else's site"
    end
  end

  describe "a client that keeps no cookies" do
    test "each request is its own session, and each carries an init" do
      request("/", %{}, opts(), headers: [{"user-agent", "ClaudeBot/1.0"}])
      {first, _} = captured_beacon()

      request("/llms.txt", %{}, opts(), headers: [{"user-agent", "ClaudeBot/1.0"}])
      {second, _} = captured_beacon()

      refute first["s"] == second["s"]

      # A session nothing else will describe: if the plug did not send init here,
      # the visit would have no user agent and so no crawler classification.
      assert init_event(first)["ua"] == "ClaudeBot/1.0"
      assert init_event(second)["ua"] == "ClaudeBot/1.0"
    end
  end

  describe "init" do
    test "is sent for a session the plug opens" do
      request("/", %{}, opts(), headers: [{"referer", "https://news.example/story"}])
      {payload, _} = captured_beacon()

      assert init = init_event(payload)
      assert init["ref"] == "https://news.example/story"
    end

    test "is not repeated once the session exists" do
      conn = request("/")
      captured_beacon()

      request("/about", carry(resp_cookies(conn)))
      {payload, _} = captured_beacon()

      refute init_event(payload),
             "a second init would overwrite what the visit arrived with"
    end
  end

  # The browser returns every cookie the response set.
  defp carry(resp_cookies), do: Map.take(resp_cookies, ["wa_sid", "wa_srv", "wa_vid"])
end
