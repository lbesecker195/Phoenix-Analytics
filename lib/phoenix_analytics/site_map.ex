defmodule PhoenixAnalytics.SiteMap do
  @moduledoc """
  What this node has actually served, kept in memory.

  The plug sees every page this application hands out, which is a better
  description of a site than anything it declares about itself: it is the set of
  pages that exist *and* get asked for, in the proportions they get asked for.
  That is exactly what an agent arriving cold wants to know, and it is knowledge
  no configuration file has.

  Deliberately local and deliberately forgettable. There is no database here and
  there will not be one — this is a library installed into someone else's
  application, and the honest scope of what it can answer without one is "what
  this node has served recently". The analytics service holds the durable
  history; this holds enough to orient a caller.

  The table is bounded. Past `max_paths` the least recently seen entries are
  dropped, so a site with unbounded URLs — search queries, pagination, ids —
  costs a fixed amount of memory rather than a growing one.
  """

  use GenServer

  @table __MODULE__
  @default_max_paths 2_000

  # Enough to tell a crawler from a person without pretending to be the
  # classifier. The analytics service does the real work on the user agent; this
  # only needs to split the local counts two ways.
  @agentish ~r/bot\b|bot\/|crawl|spider|scrape|slurp|headless|curl\/|wget|python-requests|httpx|okhttp|go-http-client|axios|node-fetch|undici|postmanruntime|scrapy|gptbot|chatgpt|oai-searchbot|claudebot|claude-web|claude-user|anthropic|perplexity|ccbot|bytespider|cohere-ai|diffbot|amazonbot|google-extended|applebot-extended|meta-external|mcp/i

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Notes that `path` was served. Never blocks the caller."
  def record(path, user_agent) when is_binary(path) do
    GenServer.cast(__MODULE__, {:record, path, agentish?(user_agent), System.os_time(:second)})
  catch
    :exit, _ -> :ok
  end

  def record(_path, _user_agent), do: :ok

  @doc "Whether a user agent looks like something other than a person's browser."
  def agentish?(user_agent) when is_binary(user_agent), do: Regex.match?(@agentish, user_agent)
  def agentish?(_), do: false

  @doc """
  The most-requested pages, most first.

  Each entry carries how often it was served, how much of that was non-browser
  traffic, and when it was last asked for.
  """
  def pages(limit \\ 50) do
    @table
    |> safe_tab2list()
    |> Enum.sort_by(fn {_path, hits, _agent, last} -> {-hits, -last} end)
    |> Enum.take(limit)
    |> Enum.map(fn {path, hits, agent_hits, last_seen} ->
      %{
        path: path,
        requests: hits,
        agent_requests: agent_hits,
        last_seen: DateTime.from_unix!(last_seen)
      }
    end)
  end

  @doc "A summary of everything this node has served since it started."
  def activity do
    entries = safe_tab2list(@table)

    requests = Enum.reduce(entries, 0, fn {_p, hits, _a, _l}, acc -> acc + hits end)
    agent_requests = Enum.reduce(entries, 0, fn {_p, _h, agent, _l}, acc -> acc + agent end)

    %{
      pages: length(entries),
      requests: requests,
      agent_requests: agent_requests,
      browser_requests: requests - agent_requests,
      since: since()
    }
  end

  @doc "Forgets everything. For tests."
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok,
     %{
       table: table,
       max_paths: Keyword.get(opts, :max_paths, @default_max_paths),
       since: DateTime.utc_now()
     }}
  end

  @impl true
  def handle_cast({:record, path, agentish?, now}, state) do
    agent_increment = if agentish?, do: 1, else: 0

    :ets.update_counter(
      @table,
      path,
      [{2, 1}, {3, agent_increment}, {4, 1, 0, now}],
      {path, 0, 0, now}
    )

    {:noreply, evict(state)}
  end

  @impl true
  def handle_call(:since, _from, state), do: {:reply, state.since, state}

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # A site can mint URLs faster than anyone can read them — search strings,
  # pagination, identifiers. Dropping the least recently seen keeps the useful
  # part of the map and puts a ceiling on what this costs its host.
  defp evict(state) do
    if :ets.info(@table, :size) > state.max_paths do
      @table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_path, _hits, _agent, last} -> last end)
      |> Enum.take(div(state.max_paths, 4))
      |> Enum.each(fn {path, _, _, _} -> :ets.delete(@table, path) end)
    end

    state
  end

  defp since do
    case Process.whereis(__MODULE__) do
      nil -> nil
      pid -> GenServer.call(pid, :since, 1_000)
    end
  catch
    :exit, _ -> nil
  end

  defp safe_tab2list(table) do
    :ets.tab2list(table)
  rescue
    ArgumentError -> []
  end
end
