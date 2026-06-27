defmodule Pux.OtpParser do
  @moduledoc """
  Extract OTP codes from email bodies. Emails are never persisted.
  """

  @type result :: %{
          otp: String.t(),
          sender_label: String.t(),
          parser: atom()
        }

  @generic_patterns [
    ~r/(?:OTP|one[\s-]?time(?:\s+password)?|verification(?:\s+code)?|auth(?:entication)?\s+code)\s*(?:is|:)?\s*(\d{4,8})/i,
    ~r/\b(\d{6})\b.*(?:OTP|one[\s-]?time|verification)/i,
    ~r/(?:OTP|code)\s*[:#]?\s*(\d{4,8})/i
  ]

  @bank_parsers %{
    hdfc: {~r/HDFC/i, ~r/(?:OTP|code)\s*(?:is|:)?\s*(\d{4,8})/i, "HDFC Bank"},
    icici: {~r/ICICI/i, ~r/(?:OTP|code)\s*(?:is|:)?\s*(\d{4,8})/i, "ICICI Bank"},
    sbi: {~r/(?:SBI|State Bank)/i, ~r/(?:OTP|code)\s*(?:is|:)?\s*(\d{4,8})/i, "SBI"},
    axis: {~r/Axis/i, ~r/(?:OTP|code)\s*(?:is|:)?\s*(\d{4,8})/i, "Axis Bank"},
    kotak: {~r/Kotak/i, ~r/(?:OTP|code)\s*(?:is|:)?\s*(\d{4,8})/i, "Kotak Bank"},
    yes: {~r/YES Bank/i, ~r/(?:OTP|code)\s*(?:is|:)?\s*(\d{4,8})/i, "YES Bank"},
    idfc: {~r/IDFC/i, ~r/(?:OTP|code)\s*(?:is|:)?\s*(\d{4,8})/i, "IDFC FIRST Bank"}
  }

  @spec parse(String.t(), keyword()) :: {:ok, result()} | {:error, :no_otp}
  def parse(body, opts \\ []) when is_binary(body) do
    sender = Keyword.get(opts, :from, "")
    subject = Keyword.get(opts, :subject, "")
    haystack = "#{subject}\n#{body}"

    with {:error, :no_otp} <- parse_bank(haystack, sender),
         {:error, :no_otp} <- parse_generic(haystack) do
      {:error, :no_otp}
    end
  end

  defp parse_bank(haystack, sender) do
    Enum.reduce_while(@bank_parsers, {:error, :no_otp}, fn {bank, {marker, pattern, label}},
                                                           _acc ->
      if marker =~ sender or marker =~ haystack do
        case Regex.run(pattern, haystack, capture: :all_but_first) do
          [otp] ->
            {:halt, {:ok, %{otp: otp, sender_label: label, parser: bank}}}

          _ ->
            {:cont, {:error, :no_otp}}
        end
      else
        {:cont, {:error, :no_otp}}
      end
    end)
  end

  defp parse_generic(haystack) do
    Enum.reduce_while(@generic_patterns, {:error, :no_otp}, fn pattern, _acc ->
      case Regex.run(pattern, haystack, capture: :all_but_first) do
        [otp] ->
          {:halt, {:ok, %{otp: otp, sender_label: "Unknown sender", parser: :generic}}}

        _ ->
          {:cont, {:error, :no_otp}}
      end
    end)
  end
end
