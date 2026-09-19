defmodule PhoenixAnalyticsTest do
  @moduledoc """
  The promise that lets someone install this into an application they care about:
  measurement can fail, and the page still renders.
  """

  use PhoenixAnalytics.ConnCase, async: false

  defmodule RaisingTransport do
    @behaviour PhoenixAnalytics.Transport

    @impl true
    def deliver(_payload, _request, _config), do: raise("the collector is down")
  end

  test "a transport that blows up neither breaks the response nor the reporter" do
    reporter = Process.whereis(PhoenixAnalytics.Reporter)

    conn = request("/", %{}, opts(transport: RaisingTransport))

    assert conn.status == 200
    assert conn.resp_body == "<html></html>"

    PhoenixAnalytics.Reporter.flush()

    assert Process.alive?(reporter), "a failed beacon took the reporter down with it"
    assert Process.whereis(PhoenixAnalytics.Reporter) == reporter, "the reporter restarted"
  end

  test "a predicate that raises costs the measurement and nothing else" do
    conn = request("/", %{}, opts(ignore_paths: [fn _path -> raise "bad matcher" end]))

    assert conn.status == 200
    assert conn.resp_body == "<html></html>"
    refute_beacon()
  end

  test "the response is not delayed by delivery" do
    # Delivery happens in a supervised task, so a slow endpoint cannot show up
    # as a slow page.
    defmodule SlowTransport do
      @behaviour PhoenixAnalytics.Transport

      @impl true
      def deliver(_payload, _request, _config) do
        Process.sleep(300)
        :ok
      end
    end

    {elapsed_us, conn} =
      :timer.tc(fn -> request("/", %{}, opts(transport: SlowTransport)) end)

    assert conn.status == 200
    assert elapsed_us < 100_000, "the request waited on the beacon"

    PhoenixAnalytics.Reporter.flush()
  end

  test "version/0 reports the library version" do
    assert PhoenixAnalytics.version() =~ ~r/^\d+\.\d+\.\d+$/
  end
end
