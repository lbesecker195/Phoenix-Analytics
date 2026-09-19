defmodule PhoenixAnalytics.ConfigTest do
  use ExUnit.Case, async: false

  alias PhoenixAnalytics.Config

  describe "the collect endpoint" do
    test "defaults to the hosted service" do
      System.delete_env("SSA_COLLECT_URL")

      assert Config.build([]) |> Config.resolve() |> Map.fetch!(:endpoint) ==
               Config.hosted_endpoint()
    end

    test "follows SSA_COLLECT_URL for a self-hosted deployment" do
      # One environment variable rather than a code change, which is the whole
      # difference between self-hosting being easy and being a fork.
      System.put_env("SSA_COLLECT_URL", "https://analytics.internal/api/v1/collect")
      on_exit(fn -> System.delete_env("SSA_COLLECT_URL") end)

      assert Config.build([]) |> Config.resolve() |> Map.fetch!(:endpoint) ==
               "https://analytics.internal/api/v1/collect"
    end

    test "an explicit option still wins" do
      System.put_env("SSA_COLLECT_URL", "https://analytics.internal/api/v1/collect")
      on_exit(fn -> System.delete_env("SSA_COLLECT_URL") end)

      config = Config.build(endpoint: "https://chosen.test/collect") |> Config.resolve()
      assert config.endpoint == "https://chosen.test/collect"
    end
  end

  describe "the site key" do
    test "can be deferred to the environment so a release reads it at boot" do
      System.put_env("SSA_SITE_KEY_TEST", "site-abc")
      on_exit(fn -> System.delete_env("SSA_SITE_KEY_TEST") end)

      config = Config.build(site: {:system, "SSA_SITE_KEY_TEST"}) |> Config.resolve()

      assert config.site == "site-abc"
      assert Config.ready?(config)
    end

    test "a missing key leaves the plug unable to report rather than raising" do
      config = Config.build(site: {:system, "DEFINITELY_NOT_SET_ANYWHERE"}) |> Config.resolve()

      refute Config.ready?(config)
    end
  end
end
