defmodule Pux.OtpParser do
  @moduledoc """
  Extract OTP codes from email bodies. Emails are never persisted.

  The sender label comes from the From domain; the code is the best-scoring
  4-8 digit number near an OTP keyword, skipping dates, amounts and account suffixes.
  """

  @type result :: %{
          otp: String.t(),
          sender_label: String.t(),
          parser: atom()
        }

  @senders [
    {~w(hdfcbank.net hdfcbank.com hdfcbank.bank.in), :hdfc, "HDFC Bank"},
    {~w(icicibank.com icicibank.bank.in), :icici, "ICICI Bank"},
    {~w(sbi.co.in onlinesbi.com sbi.bank.in), :sbi, "SBI"},
    {~w(axisbank.com axisbank.bank.in), :axis, "Axis Bank"},
    {~w(kotak.com kotak.bank.in), :kotak, "Kotak Bank"},
    {~w(yesbank.in yes.bank.in), :yes, "YES Bank"},
    {~w(idfcfirstbank.com idfcfirst.bank.in), :idfc, "IDFC FIRST Bank"}
  ]

  @keyword ~r/\b(?:OTP|one[\s-]?time[\s-]?(?:password|passcode|pin|code)|passcode|(?:verification|security|login|sign[\s-]?in|auth(?:entication|orization)?|access|confirmation|2FA)\s+code|your\s+code)\b/i
  @candidate ~r/\b\d{4,8}\b/

  # Keyword-to-code distance windows, in characters.
  @before_window 120
  @after_window 40

  @separator_before ~r/\d[-\/.:,]$/
  @separator_after ~r/^[-\/.:,]\d/
  @amount_before ~r/(?:rs\.?|inr|usd|eur|gbp|aed|\$|₹|€|£|amount(?:\s+of)?)\s*$/iu
  @reference_before ~r/(?:ending(?:\s+(?:in|with))?|a\/c(?:\s+no\.?)?|acct|account(?:\s+(?:no\.?|number))?|card(?:\s+no\.?)?|x{2,}|\*{2,}|customer\s+(?:id|code)|ref(?:erence)?(?:\s+no\.?)?|txn\s+id|mobile|phone)\s*[:#]?\s*$/i

  @spec parse(String.t(), keyword()) :: {:ok, result()} | {:error, :no_otp}
  def parse(body, opts \\ []) when is_binary(body) do
    {parser, label} = sender(Keyword.get(opts, :from) || "")
    text = normalize("#{Keyword.get(opts, :subject, "")}\n#{body}")

    case best_candidate(text) do
      nil -> {:error, :no_otp}
      otp -> {:ok, %{otp: otp, sender_label: label, parser: parser}}
    end
  end

  @doc "Strips HTML and entities and collapses whitespace."
  @spec normalize(String.t()) :: String.t()
  def normalize(text) do
    text
    |> String.replace(~r/<(script|style)\b[^>]*>.*?<\/\1>/is, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> decode_entities()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp decode_entities(text) do
    text
    |> String.replace(~r/&#(\d+);/, fn m -> m |> String.slice(2..-2//1) |> codepoint(10) end)
    |> String.replace(~r/&#x([0-9a-f]+);/i, fn m ->
      m |> String.slice(3..-2//1) |> codepoint(16)
    end)
    |> String.replace(~r/&nbsp;/i, " ")
    |> String.replace(~r/&lt;/i, "<")
    |> String.replace(~r/&gt;/i, ">")
    |> String.replace(~r/&quot;/i, "\"")
    |> String.replace(~r/&#39;|&apos;/i, "'")
    |> String.replace(~r/&amp;/i, "&")
  end

  defp codepoint(digits, base) do
    case Integer.parse(digits, base) do
      {cp, ""} when cp in 0..0x10FFFF -> <<cp::utf8>>
      _ -> " "
    end
  rescue
    ArgumentError -> " "
  end

  defp sender(from) do
    domain =
      case Regex.run(~r/@([A-Za-z0-9.-]+)/, from, capture: :all_but_first) do
        [d] -> String.downcase(d)
        _ -> nil
      end

    Enum.find_value(@senders, fn {domains, parser, label} ->
      if domain && Enum.any?(domains, &(domain == &1 or String.ends_with?(domain, "." <> &1))),
        do: {parser, label}
    end) || {:generic, domain || "Unknown sender"}
  end

  defp best_candidate(text) do
    keywords =
      @keyword
      |> Regex.scan(text, return: :index)
      |> Enum.map(fn [{start, len}] -> {start, start + len} end)

    @candidate
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{start, len}] -> {start, len} end)
    |> Enum.reject(fn {start, len} -> excluded?(text, start, len) end)
    |> Enum.flat_map(fn {start, len} ->
      case keyword_distance(keywords, start, start + len) do
        nil -> []
        distance -> [{score(len, distance), start, binary_part(text, start, len)}]
      end
    end)
    |> Enum.max_by(fn {score, start, _} -> {score, -start} end, fn -> nil end)
    |> case do
      nil -> nil
      {_, _, otp} -> otp
    end
  end

  defp excluded?(text, start, len) do
    before = binary_part(text, max(start - 30, 0), min(start, 30))
    after_ = binary_part(text, start + len, min(byte_size(text) - start - len, 3))

    before =~ @separator_before or after_ =~ @separator_after or
      before =~ @amount_before or before =~ @reference_before
  end

  defp keyword_distance(keywords, start, stop) do
    keywords
    |> Enum.flat_map(fn {kw_start, kw_stop} ->
      cond do
        kw_stop <= start and start - kw_stop <= @before_window -> [start - kw_stop]
        kw_start >= stop and kw_start - stop <= @after_window -> [kw_start - stop]
        true -> []
      end
    end)
    |> Enum.min(fn -> nil end)
  end

  defp score(6, distance), do: 100 - distance
  defp score(_len, distance), do: 60 - distance
end
