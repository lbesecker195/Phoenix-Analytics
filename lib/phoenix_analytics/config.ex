defmodule PhoenixAnalytics.Config do
  @moduledoc """
  Resolved settings for a plug call.

  Options given to the plug win over application environment, which wins over
  the defaults here. Resolution happens in `init/1` at compile time for the
  static values and again per request for anything that may come from the
  system environment, so a release can pick up its site key at boot without the
  plug having been recompiled.
  """

  @default_endpoint "https://seriouslysimpleanalytics.com/api/v1/collect"

  # The tag's own default is 30 minutes (`data-session-timeout-min`). The two
  # have to agree: this is the lifetime written on the session cookie, and a
  # shorter one here would expire a session the tag still considers open.
  @default_session_timeout_min 30

  defstruct site: nil,
            endpoint: @default_endpoint,
            enabled: true,
            cookie_domain: nil,
            session_timeout_min: @default_session_timeout_min,
            ignore_paths: [],
            transport: PhoenixAnalytics.Transport.HTTP,
            timeout_ms: 5_000,
            forward_client_ip: true

  @type t :: %__MODULE__{}

  @doc """
  Builds a config from plug options merged over the application environment.
  """
  def build(opts) when is_list(opts) do
    env = Application.get_all_env(:phoenix_analytics_middleware)

    struct!(
      __MODULE__,
      Keyword.merge(Keyword.take(env, known_keys()), Keyword.take(opts, known_keys()))
    )
  end

  @doc """
  Late-resolves values that may be deferred.

  A site key written as `{:system, "SSA_SITE_KEY"}` or as a zero-arity function
  is read here, per request, rather than baked in at compile time.
  """
  def resolve(%__MODULE__{} = config) do
    %{config | site: value(config.site), endpoint: value(config.endpoint)}
  end

  @doc "Whether this config can actually report anything."
  def ready?(%__MODULE__{} = config) do
    config.enabled and is_binary(config.site) and config.site != "" and
      is_binary(config.endpoint) and config.endpoint != ""
  end

  @doc "Session cookie lifetime in seconds, matching the tag's sliding window."
  def session_max_age(%__MODULE__{session_timeout_min: minutes}), do: round(minutes * 60)

  defp value({:system, name}), do: System.get_env(name)
  defp value({:system, name, default}), do: System.get_env(name) || default
  defp value(fun) when is_function(fun, 0), do: fun.()
  defp value(other), do: other

  defp known_keys, do: __MODULE__ |> struct() |> Map.from_struct() |> Map.keys()
end
