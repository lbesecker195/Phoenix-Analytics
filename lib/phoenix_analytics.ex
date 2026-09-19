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

  @events_key :phoenix_analytics_events

  @doc """
  Records a named thing that happened on the server.

      conn
      |> PhoenixAnalytics.event("signup_completed", data: %{plan: "team"})
      |> redirect(to: ~p"/welcome")

  The event is not sent on its own. It rides out with the beacon the plug
  already sends for this request, which is what attaches it to the right visit
  and the right page — a conversion is only worth much if you can see the page
  it happened on and the campaign that brought it.

  Because of that, this returns a connection and the caller has to keep it. An
  event recorded on a connection that is then thrown away never happened.

  It works on requests that are not pageviews too. A `POST` that ends in a
  redirect records nothing of its own, but an event on it is filed against the
  page the visitor was on when they submitted.

  ## Options

    * `:data` — a map of coarse attributes. These are stored and shown, so keep
      them to plans, counts and outcomes. Never credentials, never prompts,
      never anything a person typed into a field.
    * `:text` — a short human-readable description.
    * `:trigger` — what caused it, when "custom" is not specific enough.
  """
  def event(%Plug.Conn{} = conn, name, opts \\ []) when is_binary(name) do
    event = %{
      name: name,
      data: Keyword.get(opts, :data, %{}),
      text: Keyword.get(opts, :text),
      trigger: Keyword.get(opts, :trigger)
    }

    Plug.Conn.put_private(conn, @events_key, buffered(conn) ++ [event])
  end

  @doc false
  def buffered(%Plug.Conn{} = conn), do: Map.get(conn.private, @events_key, [])

  @doc "The version of this library."
  def version do
    Application.spec(:phoenix_analytics_middleware, :vsn) |> to_string()
  end
end
