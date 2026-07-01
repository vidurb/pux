defmodule Pux.Fixtures do
  @moduledoc false

  alias Pux.Crypto

  @spec public_key() :: binary()
  def public_key do
    %{public: public_key, secret: _secret} = :enacl.box_keypair()
    public_key
  end

  @spec public_key_b64() :: String.t()
  def public_key_b64, do: Crypto.encode_key(public_key())
end
