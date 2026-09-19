defmodule PhoenixAnalytics.Session do
  @moduledoc """
  Session identity shared with the browser tag.

  The tag keeps a visit in two cookies: `wa_vid`, a visitor id that outlives the
  visit, and `wa_sid`, holding `"<token>.<seq>"` where `seq` is the highest
  pageview number used so far. When a document has no session of its own the tag
  seeds from that cookie and *continues* the sequence — `session.seq += 1` for
  the next pageview. Both facts are what let a plug and the tag describe one
  visit instead of two.

  ## Agreeing on a pageview number

  A pageview row is keyed on `(session_id, seq)` and upserted with `COALESCE`,
  so when both halves use the same number for the same document their data
  merges: the server contributes the URL, referrer and response timing it alone
  knows, the browser contributes scroll, dwell and paint timing the server can
  never see. Use different numbers and one page becomes two rows.

  The rule that keeps them in step:

      seq = max(cookie_seq, plug_used) + 1

  `cookie_seq` is what `wa_sid` carries and `plug_used` is the highest number
  this plug has issued, kept in its own `wa_srv` cookie. It works because this
  plug never writes a non-zero counter into `wa_sid` — it writes `"<token>.0"`
  once, when it mints a session, and afterwards only refreshes that cookie's
  lifetime. So a non-zero counter there can only have come from the tag, and
  reading it tells us precisely which number the tag is about to use.

  Walking the two cases:

    * **Tag present.** First request mints the session and writes `token.0`, so
      the tag seeds from `0` and numbers the page `1` — the same number the plug
      just used. Next navigation the tag has persisted `token.1`, the plug reads
      `1` and uses `2`, and the tag seeds from `1` and also reaches `2`.

    * **No tag at all** — an agent, a crawler, a client that runs no JavaScript.
      `wa_sid` stays at `0` forever, so numbering falls to `plug_used` and the
      visit is sequenced `1, 2, 3` by the plug alone.

  A client that keeps no cookies gets a fresh session per request, which is the
  honest answer: there is nothing tying its requests together.
  """

  alias PhoenixAnalytics.Config

  @session_cookie "wa_sid"
  @visitor_cookie "wa_vid"

  # This plug's own bookkeeping, and the reason it can tell its own writes from
  # the tag's. Kept beside `wa_sid` rather than inside it so the value the tag
  # reads is exactly the value the tag wrote.
  @server_cookie "wa_srv"

  @visitor_max_age 60 * 60 * 24 * 365

  defstruct [:token, :visitor, :seq, :new?, :cookie_seq, :last_path]

  @type t :: %__MODULE__{}

  def session_cookie, do: @session_cookie
  def visitor_cookie, do: @visitor_cookie
  def server_cookie, do: @server_cookie

  @doc """
  Reads session identity from the request's cookies, minting what is missing.

  `new?` is true when no session cookie was present, which is also the signal
  that this plug owes the `init` event: a tag seeding from a cookie marks itself
  as already reported and never sends one.
  """
  def resolve(conn) do
    cookies = conn.cookies

    {token, cookie_seq, new?} =
      case parse(cookies[@session_cookie]) do
        {token, seq} -> {token, seq, false}
        nil -> {token(), 0, true}
      end

    {used, last_path} = server_state(cookies[@server_cookie])

    %__MODULE__{
      token: token,
      visitor: visitor(cookies[@visitor_cookie]),
      cookie_seq: cookie_seq,
      seq: max(cookie_seq, used) + 1,
      last_path: last_path,
      new?: new?
    }
  end

  # The plug's own cookie carries two things: the highest number it has issued,
  # and the page it issued it for. The second is what lets a visit have a flow —
  # the endpoint only chains pages together itself for callers that let it
  # assign the numbers, and this one does not.
  defp server_state(nil), do: {0, nil}

  defp server_state(value) when is_binary(value) do
    case String.split(value, "|", parts: 2) do
      [seq, path] when path != "" -> {integer(seq), path}
      [seq] -> {integer(seq), nil}
      _ -> {0, nil}
    end
  end

  defp server_state(_), do: {0, nil}

  @doc """
  Writes the cookies back, leaving the tag's counter exactly as it was found.

  Re-writing `wa_sid` unchanged refreshes its sliding lifetime, which is what
  keeps a visit alive across requests the tag never sees.
  """
  def put_cookies(conn, %__MODULE__{} = session, %Config{} = config) do
    opts = cookie_opts(conn, config)
    max_age = Config.session_max_age(config)

    conn
    |> Plug.Conn.put_resp_cookie(
      @session_cookie,
      "#{session.token}.#{session.cookie_seq}",
      Keyword.put(opts, :max_age, max_age)
    )
    |> Plug.Conn.put_resp_cookie(
      @server_cookie,
      "#{session.seq}|#{conn.request_path}",
      Keyword.put(opts, :max_age, max_age)
    )
    |> Plug.Conn.put_resp_cookie(
      @visitor_cookie,
      session.visitor,
      Keyword.put(opts, :max_age, @visitor_max_age)
    )
  end

  # Matched to what the tag sets, because a cookie of the same name at a
  # different scope is a second cookie rather than an update, and the two would
  # disagree about which visit this is.
  defp cookie_opts(conn, config) do
    [path: "/", same_site: "Lax", http_only: false, secure: conn.scheme == :https]
    |> put_domain(domain(conn, config))
  end

  defp put_domain(opts, nil), do: opts
  defp put_domain(opts, domain), do: Keyword.put(opts, :domain, "." <> domain)

  defp domain(_conn, %Config{cookie_domain: domain}) when is_binary(domain), do: domain
  defp domain(conn, _config), do: registrable_domain(conn.host)

  @doc """
  The shortest domain a cookie can usefully be set on, or nil to keep it to this
  host.

  The tag discovers this by trying candidates against the browser, which a
  server cannot do, so this approximates it: the last two labels, or three where
  the last two are a known compound suffix. Set `:cookie_domain` for anything
  this guesses wrong — the cost of a wrong guess is a cookie the browser
  silently drops, and a visit that splits per subdomain.
  """
  def registrable_domain(host) when is_binary(host) do
    labels = String.split(host, ".")

    cond do
      # An address, or a single-label host like `localhost`: both take a
      # host-only cookie and nothing else.
      host =~ ~r/^[\d.]+$/ or length(labels) < 2 -> nil
      compound_suffix?(labels) and length(labels) >= 3 -> join_last(labels, 3)
      true -> join_last(labels, 2)
    end
  end

  def registrable_domain(_), do: nil

  @compound_second_level ~w(co com net org gov edu ac gouv)

  defp compound_suffix?(labels) do
    case Enum.take(labels, -2) do
      [second, tld] -> second in @compound_second_level and String.length(tld) == 2
      _ -> false
    end
  end

  defp join_last(labels, n), do: labels |> Enum.take(-n) |> Enum.join(".")

  defp parse(nil), do: nil

  defp parse(value) when is_binary(value) do
    case String.split(value, ".", parts: 2) do
      [token | rest] when token != "" ->
        {token, rest |> List.first() |> integer()}

      _ ->
        nil
    end
  end

  defp parse(_), do: nil

  defp integer(nil), do: 0

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 0 -> n
      _ -> 0
    end
  end

  defp integer(_), do: 0

  defp visitor(value) when is_binary(value) and value != "", do: value
  defp visitor(_), do: token()

  # The tag uses `crypto.randomUUID()`; matching the shape keeps the two
  # indistinguishable in storage, which they should be — they identify the same
  # kind of thing.
  defp token do
    <<a::32, b::16, _::4, c::12, _::2, d::62>> = :crypto.strong_rand_bytes(16)

    [
      pad(a, 8),
      pad(b, 4),
      "4" <> pad(c, 3),
      hd_variant(d),
      pad(Bitwise.band(d, 0xFFFFFFFFFFFF), 12)
    ]
    |> Enum.join("-")
  end

  defp hd_variant(d), do: pad(Bitwise.bor(0x8000, Bitwise.bsr(d, 48) |> Bitwise.band(0x3FFF)), 4)

  defp pad(value, width),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
end
