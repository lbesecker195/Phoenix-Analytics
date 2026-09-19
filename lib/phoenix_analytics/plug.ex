defmodule PhoenixAnalytics.Plug do
  @moduledoc """
  Records server-side pageviews into Seriously Simple Analytics.

  Add it to an endpoint, above the router and below `Plug.Static` so static
  files never reach it:

      plug PhoenixAnalytics.Plug,
        site: {:system, "SSA_SITE_KEY"}

  Or to a single router pipeline, when only part of an application should be
  measured:

      pipeline :browser do
        # ...
        plug PhoenixAnalytics.Plug, site: {:system, "SSA_SITE_KEY"}
      end

  ## What it adds to the browser tag

  The tag already measures anything with a browser around it, and measures it
  better than a server can — scroll depth, dwell, clicks, paint timing. This
  plug is not a replacement for it and does not try to be. It contributes the
  two things the tag structurally cannot:

    * **Traffic that runs no JavaScript.** Crawlers, AI agents, scripts and API
      clients are invisible to a tag that has to execute to report. They are
      ordinary requests here.

    * **The first moments of a visit.** The tag reports once it has loaded and
      run. A session opened by this plug already carries the landing page,
      referrer and campaign before a single byte of JavaScript has executed, so
      a visitor who leaves immediately is still a visit with a source.

  Where both are running they share one session and one pageview row rather than
  counting a visit twice — see `PhoenixAnalytics.Session` for how the two agree
  on a number.

  ## Options

    * `:site` — the site key, required. Also accepts `{:system, "VAR"}` or a
      zero-arity function so a release can read it at boot.
    * `:endpoint` — collect URL. Defaults to the hosted endpoint.
    * `:enabled` — set false to turn the plug into a no-op, for a test suite or
      a review app.
    * `:ignore_paths` — prefixes, regexes or predicates that should never be
      recorded. Health checks and webhooks belong here.
    * `:cookie_domain` — the domain to scope the visit cookies to. Defaults to
      the registrable domain of the request, which is what the tag uses.
    * `:session_timeout_min` — must match the tag's `data-session-timeout-min`.
      Defaults to 30, as the tag does.
    * `:forward_client_ip` — whether to pass the visitor's address to the
      endpoint. Defaults to true.
    * `:transport` — a `PhoenixAnalytics.Transport` implementation.

  Any of these can also be set in application config under
  `:phoenix_analytics_middleware`; options given here win.
  """

  @behaviour Plug

  require Logger

  alias PhoenixAnalytics.Config
  alias PhoenixAnalytics.Payload
  alias PhoenixAnalytics.Reporter
  alias PhoenixAnalytics.Request
  alias PhoenixAnalytics.Session

  @impl true
  def init(opts), do: Config.build(opts)

  @impl true
  def call(conn, %Config{} = config) do
    config = Config.resolve(config)

    if Config.ready?(config) do
      started = System.monotonic_time()

      conn
      |> Plug.Conn.fetch_cookies()
      |> Plug.Conn.register_before_send(&before_send(&1, config, started))
    else
      conn
    end
  end

  # Runs with the response already built, which is the only point where the
  # status and content type are known — and those decide whether this was a
  # pageview at all.
  #
  # Wrapped because this is somebody else's response. A bug here, or a
  # malformed header, must cost the visit's measurement and nothing else: the
  # page still renders.
  defp before_send(conn, config, started) do
    if Request.trackable?(conn, config.ignore_paths) do
      record(conn, config, started)
    else
      conn
    end
  rescue
    error ->
      Logger.debug("phoenix_analytics: skipped a request: #{Exception.message(error)}")
      conn
  end

  defp record(conn, config, started) do
    session = Session.resolve(conn)

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    request = Request.extract(conn, duration_ms)

    config.site
    |> Payload.build(session, request, System.os_time(:millisecond))
    |> Reporter.report(request, config)

    Session.put_cookies(conn, session, config)
  end
end
