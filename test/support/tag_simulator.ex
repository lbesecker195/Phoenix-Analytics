defmodule PhoenixAnalytics.TagSimulator do
  @moduledoc """
  A model of the parts of `wa.js` that decide a pageview's number.

  The integration this library claims rests on one thing: that a browser tag and
  a server, both looking at the same cookie, pick the same number for the same
  page. That claim is only worth as much as the model of the tag it is checked
  against, so this mirrors the tag's actual logic rather than a convenient
  paraphrase of it:

    * a document with no `sessionStorage` session seeds from the `wa_sid` cookie,
      taking `"<token>.<seq>"` and continuing from that `seq`
    * opening a pageview does `session.seq += 1` and reports that number
    * every persist writes `"<token>.<seq>"` back to the cookie

  Anything the tag does that cannot change a pageview number is left out.
  """

  defstruct [:token, :seq, :storage]

  @doc "A fresh document, as a browser that just navigated would have."
  def new_document(cookies) do
    case cookies["wa_sid"] do
      value when is_binary(value) ->
        [token | rest] = String.split(value, ".", parts: 2)
        seq = rest |> List.first() |> parse_int()
        %__MODULE__{token: token, seq: seq, storage: :seeded}

      _ ->
        %__MODULE__{
          token: "tag-" <> Integer.to_string(:erlang.unique_integer([:positive])),
          seq: 0,
          storage: :fresh
        }
    end
  end

  @doc "Opens a pageview. Returns the sequence number the tag reports for it."
  def open_pageview(%__MODULE__{} = tag) do
    tag = %{tag | seq: tag.seq + 1}
    {tag, tag.seq}
  end

  @doc "The cookie the tag leaves behind after persisting."
  def cookie(%__MODULE__{} = tag), do: "#{tag.token}.#{tag.seq}"

  defp parse_int(nil), do: 0

  defp parse_int(value) do
    case Integer.parse(value) do
      {n, _} -> n
      _ -> 0
    end
  end
end
