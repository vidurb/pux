defmodule Pux.CryptoTest do
  use ExUnit.Case, async: true

  alias Pux.Crypto

  # Shared with the mobile client's crypto test: a fixed sealed box produced by
  # this server, so both sides agree on key/ciphertext encoding.
  @fixture %{
    public_key: "6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw",
    secret_key: "vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI",
    ciphertext:
      "Xso7kEp1NhYtxtQC5hMfioNb2Q3_Y3KadFsVXxDtJRJ3KVUY_KqedKRIW-w4kMKf8SHpQ3FYbIJ7T8cM5LM-tCLJrk6Dyqe1J60Fu13SM6Ci1fISV_VAN9fI0WxPAdzUOBLSqhoVNlmvDg60KTX6k-ubO7gtRDmh8Jit8g3OMYhKV_KLn45FJKGjqF5ERXM6cmyCouvd2feDRw",
    plaintext:
      ~s({"type":"otp","otp":"123456","sender":"Test Bank","received_at":"2026-10-06T00:00:00Z","parser":"generic"})
  }

  test "sealed box roundtrip encoding" do
    %{public: public_key, secret: private_key} = :enacl.box_keypair()
    plaintext = "hello otp"

    assert {:ok, ciphertext} = Crypto.seal(plaintext, public_key)
    assert {:ok, decoded_pub} = Crypto.decode_key(Crypto.encode_key(public_key))
    assert {:ok, decoded_priv} = Crypto.decode_key(Crypto.encode_key(private_key))
    assert decoded_pub == public_key
    assert decoded_priv == private_key
    assert {:ok, ^plaintext} = :enacl.box_seal_open(ciphertext, public_key, private_key)
  end

  test "opens the shared cross-client fixture" do
    {:ok, pk} = Crypto.decode_key(@fixture.public_key)
    {:ok, sk} = Crypto.decode_key(@fixture.secret_key)
    {:ok, ciphertext} = Base.url_decode64(@fixture.ciphertext, padding: false)

    assert {:ok, @fixture.plaintext} == :enacl.box_seal_open(ciphertext, pk, sk)
  end
end
