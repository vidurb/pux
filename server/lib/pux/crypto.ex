defmodule Pux.Crypto do
  @moduledoc """
  libsodium sealed-box helpers. The server only ever encrypts with the record public key.
  """

  @type keypair :: %{public_key: binary(), private_key: binary()}

  @spec generate_keypair() :: keypair()
  def generate_keypair do
    %{public: public_key, secret: private_key} = :enacl.box_keypair()
    %{public_key: public_key, private_key: private_key}
  end

  @spec seal(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def seal(plaintext, public_key) when is_binary(plaintext) and is_binary(public_key) do
    try do
      {:ok, :enacl.box_seal(plaintext, public_key)}
    rescue
      e -> {:error, e}
    end
  end

  @spec encode_key(binary()) :: String.t()
  def encode_key(key), do: Base.url_encode64(key, padding: false)

  @spec decode_key(String.t()) :: {:ok, binary()} | {:error, :invalid}
  def decode_key(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      _ -> {:error, :invalid}
    end
  end

  @spec encode_ciphertext(binary()) :: String.t()
  def encode_ciphertext(ciphertext), do: Base.url_encode64(ciphertext, padding: false)
end
