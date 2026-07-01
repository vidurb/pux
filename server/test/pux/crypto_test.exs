defmodule Pux.CryptoTest do
  use ExUnit.Case, async: true

  alias Pux.Crypto

  test "sealed box roundtrip encoding" do
    %{public: public_key, secret: private_key} = :enacl.box_keypair()
    plaintext = "hello otp"

    assert {:ok, ciphertext} = Crypto.seal(plaintext, public_key)
    assert {:ok, decoded_pub} = Crypto.decode_key(Crypto.encode_key(public_key))
    assert {:ok, decoded_priv} = Crypto.decode_key(Crypto.encode_key(private_key))
    assert decoded_pub == public_key
    assert decoded_priv == private_key
    assert {:ok, plaintext} = :enacl.box_seal_open(ciphertext, public_key, private_key)
  end
end
