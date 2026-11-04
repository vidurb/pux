defmodule Pux.DKIMTestResolver do
  @moduledoc "DKIM key resolver for tests, backed by `:persistent_term`. Never touches the network."
  @behaviour Pux.DKIMResolver

  @doc "Publishes `value` (TXT string, list of strings, or `{:sleep, ms}`) at `name`."
  def put(name, value), do: :persistent_term.put({__MODULE__, String.downcase(name)}, value)

  @impl true
  def lookup_txt(name, _timeout_ms) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil ->
        {:error, :nxdomain}

      {:sleep, ms} ->
        Process.sleep(ms)
        {:error, :timeout}

      txt ->
        {:ok, List.wrap(txt)}
    end
  end
end
