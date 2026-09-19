defmodule PhoenixAnalytics.TrackableTest do
  @moduledoc """
  What gets recorded and what does not.

  Over-recording is the expensive mistake here: an asset or an XHR that claims a
  pageview number takes one the browser tag was going to use, and the two halves
  of a visit stop lining up.
  """

  use PhoenixAnalytics.ConnCase, async: false

  describe "browsers, which say what a response is for" do
    test "a navigation is recorded" do
      request("/", %{}, opts(), headers: [{"sec-fetch-dest", "document"}])
      {payload, _} = captured_beacon()
      assert pageview(payload)["path"] == "/"
    end

    test "a stylesheet is not" do
      request("/app.css", %{}, opts(),
        headers: [{"sec-fetch-dest", "style"}],
        content_type: "text/css"
      )

      refute_beacon()
    end

    test "a background fetch is not, even when it returns a document" do
      # An XHR for an HTML fragment is the case a content-type test alone gets
      # wrong, and LiveView applications are full of them.
      request("/search", %{}, opts(), headers: [{"sec-fetch-dest", "empty"}])
      refute_beacon()
    end

    test "an image is not" do
      request("/logo.png", %{}, opts(),
        headers: [{"sec-fetch-dest", "image"}],
        content_type: "image/png"
      )

      refute_beacon()
    end
  end

  describe "clients that say nothing about intent" do
    test "a crawler reading a page is recorded" do
      request("/", %{}, opts(), headers: [{"user-agent", "GPTBot/1.1"}])
      {payload, _} = captured_beacon()
      assert pageview(payload)["path"] == "/"
    end

    test "an agent reading llms.txt is recorded" do
      request("/llms.txt", %{}, opts(),
        headers: [{"user-agent", "ClaudeBot/1.0"}],
        content_type: "text/plain"
      )

      {payload, _} = captured_beacon()
      assert pageview(payload)["path"] == "/llms.txt"
    end

    test "an API client reading JSON is recorded" do
      request("/api/v1/keywords", %{}, opts(), content_type: "application/json")
      {payload, _} = captured_beacon()
      assert pageview(payload)["path"] == "/api/v1/keywords"
    end

    test "a binary download is not" do
      request("/report.pdf", %{}, opts(), content_type: "application/pdf")
      refute_beacon()
    end
  end

  describe "regardless of client" do
    test "a redirect is not recorded" do
      # The page it redirects to will be, and counting both would put two
      # pageviews behind one navigation.
      request("/old", %{}, opts(), status: 302)
      refute_beacon()
    end

    test "a not-found is not recorded" do
      request("/nope", %{}, opts(), status: 404)
      refute_beacon()
    end

    test "a POST is not recorded" do
      request("/checkout", %{}, opts(), method: "POST")
      refute_beacon()
    end

    test "ignored paths are not recorded" do
      plug = opts(ignore_paths: ["/health", ~r{^/internal/}])

      request("/health", %{}, plug)
      refute_beacon()

      request("/internal/metrics", %{}, plug)
      refute_beacon()

      request("/", %{}, plug)
      assert {_payload, _} = captured_beacon()
    end

    test "no cookies are set on a response that is not recorded" do
      conn = request("/app.css", %{}, opts(), headers: [{"sec-fetch-dest", "style"}])
      assert resp_cookies(conn) == %{}
    end
  end

  describe "when the plug cannot report" do
    test "a missing site key makes it a no-op" do
      conn = request("/", %{}, opts(site: nil))
      refute_beacon()
      assert resp_cookies(conn) == %{}
    end

    test "being disabled makes it a no-op" do
      conn = request("/", %{}, opts(enabled: false))
      refute_beacon()
      assert resp_cookies(conn) == %{}
    end
  end
end
