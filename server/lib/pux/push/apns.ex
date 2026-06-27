defmodule Pux.Push.APNs do
  @moduledoc """
  APNs push scaffold. Deferred for Android-first alpha.
  """

  require Logger

  @spec deliver(String.t(), map()) :: :ok
  def deliver(push_token, _envelope) when is_binary(push_token) do
    Logger.debug("APNs not configured; would push to #{String.slice(push_token, 0, 8)}...")
    :ok
  end
end
