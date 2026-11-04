defmodule Pux.DKIMResolver do
  @moduledoc """
  TXT lookup for DKIM keys. Swap the implementation with
  `config :pux, :dkim, resolver: Module` (tests never touch the network).
  """

  @callback lookup_txt(name :: String.t(), timeout_ms :: non_neg_integer()) ::
              {:ok, [binary()]} | {:error, term()}

  @behaviour __MODULE__

  @impl true
  def lookup_txt(name, timeout_ms) do
    case :inet_res.lookup(String.to_charlist(name), :in, :txt, [], timeout_ms) do
      [] -> {:error, :nxdomain}
      records -> {:ok, Enum.map(records, &IO.iodata_to_binary/1)}
    end
  end
end
