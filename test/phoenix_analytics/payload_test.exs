defmodule PhoenixAnalytics.PayloadTest do
  @moduledoc "What the server contributes that a browser cannot."

  use PhoenixAnalytics.ConnCase, async: false

  describe "the pageview" do
    test "carries the full location of the page" do
      request("/docs/install?ref=hn", %{}, opts(), host: "www.example.com")
      {payload, _} = captured_beacon()
      pv = pageview(payload)

      assert pv["path"] == "/docs/install"
      assert pv["url"] == "http://www.example.com/docs/install?ref=hn"
      assert pv["host"] == "www.example.com"
      assert pv["q"] == "ref=hn"
      assert pv["proto"] == "http"
    end

    test "reports time to first byte, which the server alone measures for every response" do
      request("/")
      {payload, _} = captured_beacon()

      assert is_integer(pageview(payload)["perf"]["ttfb"])
      assert pageview(payload)["perf"]["nt"] == "navigate"
    end

    test "omits what it has nothing to say about" do
      # The endpoint coerces absent keys to nil anyway; sending them is bytes on
      # a real network hop for no gain.
      request("/")
      {payload, _} = captured_beacon()
      pv = pageview(payload)

      refute Map.has_key?(pv, "q")
      refute Map.has_key?(pv, "ref")
    end
  end

  describe "the init event" do
    test "captures the campaign a visit arrived on" do
      request("/?utm_source=twitter&utm_medium=social&utm_campaign=launch&other=1")
      {payload, _} = captured_beacon()

      assert init_event(payload)["utm"] == %{
               "source" => "twitter",
               "medium" => "social",
               "campaign" => "launch"
             }
    end

    test "captures the user agent, which is how a crawler gets classified" do
      request("/", %{}, opts(), headers: [{"user-agent", "PerplexityBot/1.0"}])
      {payload, _} = captured_beacon()

      assert init_event(payload)["ua"] == "PerplexityBot/1.0"
    end

    test "takes the preferred language without its quality weight" do
      request("/", %{}, opts(), headers: [{"accept-language", "en-GB,en;q=0.9,fr;q=0.8"}])
      {payload, _} = captured_beacon()

      assert init_event(payload)["lang"] == "en-GB"
    end
  end

  describe "what travels alongside the beacon" do
    test "the visitor's address, not this server's" do
      # The beacon is posted by the server, so without this every visit would
      # geolocate to wherever the application runs.
      request("/", %{}, opts(), headers: [{"x-forwarded-for", "203.0.113.42, 70.41.3.18"}])
      {_payload, request} = captured_beacon()

      assert request.client_ip == "203.0.113.42"
    end

    test "the visitor's CDN geolocation headers" do
      request("/", %{}, opts(), headers: [{"cf-ipcountry", "DE"}, {"cf-ipcity", "Berlin"}])

      {_payload, request} = captured_beacon()

      assert {"cf-ipcountry", "DE"} in request.geo_headers
      assert {"cf-ipcity", "Berlin"} in request.geo_headers
    end

    test "the address is withheld when configured to be" do
      request("/", %{}, opts(), headers: [{"x-forwarded-for", "203.0.113.42"}])
      {_payload, request} = captured_beacon()

      forwarding =
        PhoenixAnalytics.Transport.HTTP.headers(request, PhoenixAnalytics.Config.build([]))

      withheld =
        PhoenixAnalytics.Transport.HTTP.headers(
          request,
          PhoenixAnalytics.Config.build(forward_client_ip: false)
        )

      assert {~c"x-forwarded-for", ~c"203.0.113.42"} in forwarding
      refute List.keymember?(withheld, ~c"x-forwarded-for", 0)
    end
  end

  describe "the beacon envelope" do
    test "identifies the site, session and visitor" do
      request("/")
      {payload, _} = captured_beacon()

      assert payload["k"] == "test-site"
      assert is_binary(payload["s"])
      assert is_binary(payload["v"])
      assert is_integer(payload["t"])
    end

    test "is valid JSON for the endpoint" do
      request("/?utm_source=x")
      {payload, _} = captured_beacon()

      assert {:ok, encoded} = Jason.encode(payload)
      assert {:ok, decoded} = Jason.decode(encoded)
      assert decoded["k"] == "test-site"
    end
  end
end
