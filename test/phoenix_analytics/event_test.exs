defmodule PhoenixAnalytics.EventTest do
  @moduledoc """
  Server-side conversions, filed against the visit and page they happened on.
  """

  use PhoenixAnalytics.ConnCase, async: false

  describe "an event on a page request" do
    test "rides out with that page's beacon" do
      run("/pricing", fn conn ->
        PhoenixAnalytics.event(conn, "signup_completed", data: %{"plan" => "team"})
      end)

      {payload, _} = captured_beacon()

      assert event = Enum.find(payload["e"], &(&1["n"] == "event"))
      assert event["name"] == "signup_completed"
      assert event["data"] == %{"plan" => "team"}

      # Filed against the page it happened on, which is the whole point: a
      # conversion you cannot attribute to a page is a number without a cause.
      assert event["pv"] == pageview(payload)["seq"]
    end

    test "several events keep their order" do
      run("/checkout", fn conn ->
        conn
        |> PhoenixAnalytics.event("cart_priced")
        |> PhoenixAnalytics.event("payment_taken")
      end)

      {payload, _} = captured_beacon()

      names = payload["e"] |> Enum.filter(&(&1["n"] == "event")) |> Enum.map(& &1["name"])
      assert names == ["cart_priced", "payment_taken"]
    end
  end

  describe "an event on a request that is not a page" do
    test "is still recorded, against the page the visitor was on" do
      # A POST that redirects records no pageview of its own. The signup still
      # happened, and it happened on the page holding the form.
      conn = request("/signup")
      captured_beacon()
      cookies = carry(resp_cookies(conn))

      run(
        "/signup",
        fn conn -> PhoenixAnalytics.event(conn, "signup_completed") end,
        cookies,
        method: "POST",
        status: 302
      )

      {payload, _} = captured_beacon()

      refute Enum.find(payload["e"], &(&1["n"] == "pv")), "a redirect is not a pageview"
      assert event = Enum.find(payload["e"], &(&1["n"] == "event"))
      assert event["name"] == "signup_completed"
      assert event["pv"] == 1, "the event should belong to the page the form was on"
    end

    test "does not consume a pageview number the tag is about to use" do
      conn = request("/signup")
      captured_beacon()
      cookies = carry(resp_cookies(conn))

      conn =
        run(
          "/signup",
          fn conn -> PhoenixAnalytics.event(conn, "signup_completed") end,
          cookies,
          method: "POST",
          status: 302
        )

      captured_beacon()

      # Still 1: the POST took no number. If it had, the next real page would be
      # 3 while the tag called it 2, and they would stop describing one visit.
      assert resp_cookies(conn)["wa_srv"] == "1|/signup"

      request("/welcome", carry(resp_cookies(conn)))
      {payload, _} = captured_beacon()
      assert pageview(payload)["seq"] == 2
    end
  end

  describe "a request with neither a page nor an event" do
    test "sends nothing at all" do
      run("/api/webhook", fn conn -> conn end, %{}, method: "POST", status: 204)
      refute_beacon()
    end
  end

  # Runs a request, letting `during` touch the connection the way a controller
  # would, before the response is sent.
  defp run(path, during, cookies \\ %{}, overrides \\ []) do
    Plug.Test.conn(Keyword.get(overrides, :method, "GET"), path)
    |> Map.put(:host, "www.example.com")
    |> then(fn c ->
      if map_size(cookies) == 0 do
        c
      else
        Plug.Conn.put_req_header(
          c,
          "cookie",
          Enum.map_join(cookies, "; ", fn {k, v} -> "#{k}=#{v}" end)
        )
      end
    end)
    |> PhoenixAnalytics.Plug.call(opts())
    |> during.()
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(Keyword.get(overrides, :status, 200), "<html></html>")
  end

  defp carry(resp_cookies), do: Map.take(resp_cookies, ["wa_sid", "wa_srv", "wa_vid"])
end
