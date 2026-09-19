defmodule PhoenixAnalytics.Transport do
  @moduledoc """
  How a beacon reaches the collect endpoint.

  A behaviour rather than a fixed call so tests can assert on what would have
  been sent, and so a host application that already runs an HTTP client can use
  it instead of the default.
  """

  alias PhoenixAnalytics.Config
  alias PhoenixAnalytics.Request

  @callback deliver(payload :: map(), request :: Request.t(), config :: Config.t()) ::
              :ok | {:error, term()}
end
