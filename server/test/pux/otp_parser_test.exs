defmodule Pux.OtpParserTest do
  use ExUnit.Case, async: true

  alias Pux.OtpParser

  test "parses generic OTP" do
    body = "Your OTP is 123456. Do not share."
    assert {:ok, %{otp: "123456"}} = OtpParser.parse(body)
  end

  test "parses HDFC OTP" do
    body = "Dear customer, OTP is 654321 for transaction."
    assert {:ok, %{otp: "654321", sender_label: "HDFC Bank"}} =
             OtpParser.parse(body, from: "alerts@hdfcbank.net")
  end

  test "returns error when no OTP" do
    assert {:error, :no_otp} = OtpParser.parse("Thanks for banking with us.")
  end
end
