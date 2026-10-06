defmodule Pux.OtpParserTest do
  use ExUnit.Case, async: true

  alias Pux.OtpParser

  test "parses generic OTP" do
    body = "Your OTP is 123456. Do not share."
    assert {:ok, %{otp: "123456", sender_label: "Unknown sender"}} = OtpParser.parse(body)
  end

  test "labels the sender from the From domain" do
    body = "Dear customer, OTP is 654321 for transaction."

    assert {:ok, %{otp: "654321", sender_label: "HDFC Bank", parser: :hdfc}} =
             OtpParser.parse(body, from: "HDFC Bank <alerts@hdfcbank.net>")

    assert {:ok, %{sender_label: "example.com", parser: :generic}} =
             OtpParser.parse(body, from: "noreply@example.com")
  end

  test "returns error when no OTP" do
    assert {:error, :no_otp} = OtpParser.parse("Thanks for banking with us.")
  end

  @samples [
    {"code before keyword, card suffix and amount nearby", "alerts@hdfcbank.net",
     "OTP for transaction",
     "Dear Customer, 482913 is the One Time Password (OTP) for your transaction of INR 5,000.00 at AMAZON on HDFC Bank Card ending 1234.",
     "482913"},
    {"masked card and amount", "credit_cards@icicibank.com", "OTP",
     "Dear Customer, Your OTP for transaction of INR 2500.00 on ICICI Bank Credit Card XX4321 is 739201. OTP is valid for 10 mins.",
     "739201"},
    {"card ending and Rs amount", "donotreply@sbi.co.in", "OTP",
     "OTP for online purchase of Rs. 1500.00 at FLIPKART thru State Bank Debit Card ending 9876 is 552910. Do not share.",
     "552910"},
    {"multi-line", "alerts@axisbank.com", "Your OTP",
     "Your One Time Password is:\n\n  382910\n\nValid for 3 minutes.", "382910"},
    {"date before code", "noreply@example.com", "Login",
     "Your verification code for login on 2026-10-06 is 4417.", "4417"},
    {"html only", "alerts@kotak.com", "OTP",
     "<html><body><p>Your OTP is <b>918273</b></p></body></html>", "918273"},
    {"amount after code", "alerts@idfcfirstbank.com", "OTP",
     "Use OTP 123456 to authorise payment of Rs 999 to MERCHANT.", "123456"},
    {"entities", "x@example.com", "Code", "Your&nbsp;verification&nbsp;code:&nbsp;771122",
     "771122"}
  ]

  for {name, from, subject, body, expected} <- @samples do
    test "extracts #{name}" do
      assert {:ok, %{otp: unquote(expected)}} =
               OtpParser.parse(unquote(body), from: unquote(from), subject: unquote(subject))
    end
  end

  test "ignores newsletter numbers without an OTP keyword" do
    body =
      "HDFC Bank: your statement for account 12345678 is ready. Customer code 99887766."

    assert {:error, :no_otp} =
             OtpParser.parse(body, from: "news@hdfcbank.net", subject: "Newsletter")
  end

  test "does not truncate longer numbers" do
    assert {:error, :no_otp} = OtpParser.parse("Your OTP reference 816235124")
  end
end
