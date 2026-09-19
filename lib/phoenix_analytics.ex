defmodule PhoenixAnalytics do
  @moduledoc """
  Server-side analytics middleware for Phoenix.

  A plug that records the requests a browser tag cannot see — AI agents,
  crawlers, API clients, and the first moments of a visit before any JavaScript
  has run — and folds them into the same Seriously Simple Analytics session the
  tag is already reporting, so one visit stays one visit.

  Start at `PhoenixAnalytics.Plug` for installation, and
  `PhoenixAnalytics.Session` for how a server and a browser end up agreeing on
  which pageview is which.
  """

  @doc "The version of this library."
  def version do
    Application.spec(:phoenix_analytics_middleware, :vsn) |> to_string()
  end
end
