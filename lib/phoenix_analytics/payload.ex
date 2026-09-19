defmodule PhoenixAnalytics.Payload do
  @moduledoc """
  Builds a beacon in the shape the collect endpoint expects.

  The wire format is the tag's: `%{"k" => site, "s" => session, "v" => visitor,
  "t" => now, "e" => events}`, where each event carries an `"n"` naming its kind.
  Only two of those kinds can be filled in from a server: `init`, describing the
  visit, and `pv`, describing one page. The rest — ticks, clicks, form activity —
  need a browser, and are left to the tag.

  Times are milliseconds. The endpoint anchors every event to its own receive
  time and applies the client's reported offset, so sending `t` from the same
  clock as the event times means no skew correction is applied.
  """

  alias PhoenixAnalytics.Session

  @utm_keys ~w(source medium campaign term content)

  @doc """
  Assembles the beacon for one request.

  `init` is included only for a session this plug minted. A tag that seeds from
  an existing cookie marks itself reported and never sends one, so if this plug
  opened the session it is the only thing that can say what user agent and
  referrer the visit arrived with.
  """
  def build(site_key, %Session{} = session, request, now_ms) do
    events =
      if session.new? do
        [init_event(request, now_ms), pageview_event(session, request, now_ms)]
      else
        [pageview_event(session, request, now_ms)]
      end

    %{
      "k" => site_key,
      "s" => session.token,
      "v" => session.visitor,
      "t" => now_ms,
      "e" => events
    }
  end

  defp init_event(request, now_ms) do
    %{
      "n" => "init",
      "t" => now_ms,
      "ua" => request.user_agent,
      "ref" => request.referrer,
      "utm" => request.utm,
      "lang" => request.language
    }
    |> prune()
  end

  defp pageview_event(%Session{} = session, request, now_ms) do
    %{
      "n" => "pv",
      "t" => now_ms,
      "seq" => session.seq,
      "path" => request.path,
      "url" => request.url,
      "host" => request.host,
      "proto" => request.protocol,
      "port" => request.port,
      "q" => request.query,
      "ref" => request.referrer,
      # Where this page was reached from, so a visit has a shape rather than a
      # pile of unrelated pages. A same-site referrer is the better answer
      # because the browser is reporting an actual navigation; the plug's own
      # record of the last page it saw covers everything that sends no referrer,
      # which is most things without a browser.
      "fp" => request.referrer_path || session.last_path,
      # Time to first byte measured where it is actually known. The browser can
      # only observe this for the document it loaded; the server observes it for
      # every response, including the ones no browser ever renders.
      "perf" => prune(%{"ttfb" => request.duration_ms, "nt" => "navigate"})
    }
    |> prune()
  end

  @doc """
  Pulls `utm_*` parameters out of a decoded query map.

  Returns a map keyed the way the endpoint reads them — `source`, `medium` and
  so on, without the prefix.
  """
  def utm(params) when is_map(params) do
    for key <- @utm_keys,
        value = params["utm_" <> key],
        is_binary(value),
        value != "",
        into: %{},
        do: {key, value}
  end

  def utm(_), do: %{}

  # Nothing is gained by sending keys the endpoint will only coerce back to nil,
  # and a beacon from a server is paying for every byte on a real network hop.
  defp prune(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" or value == %{} end)
    |> Map.new()
  end
end
