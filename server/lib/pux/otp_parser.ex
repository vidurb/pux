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
    {~w(hsbc.bank.in hsbc.co.in), :hsbc, "HSBC"},
    {~w(rbl.bank.in rblbank.com), :rbl, "RBL Bank"},
    {~w(americanexpress.com aexp.com), :amex, "American Express"}
  ]

  @keyword ~r/\b(?:OTP|one[\s-]?time[\s-]?(?:password|passcode|pin|code)|passcode|(?:verification|security|login|sign[\s-]?in|auth(?:entication|orization)?|access|confirmation|2FA)\s+code|your\s+code)\b/i
  @candidate ~r/\b\d{4,8}\b/

  # Keyword-to-code distance windows, in characters.
  @before_window 120
  @after_window 40

  # Input caps. Real OTP mail is well under 256 KB of HTML (heavy inline CSS
  # included) and its visible text a few KB, with the code near the top.
  @max_input_bytes 262_144
  @max_text_bytes 32_768

  @separator_before ~r/\d[-\/.:,]$/
  @separator_after ~r/^[-\/.:,]\d/
  @amount_before ~r/(?:rs\.?|inr|usd|eur|gbp|aed|\$|₹|€|£|amount(?:\s+of)?)\s*$/iu
  @reference_before ~r/(?:ending(?:\s+(?:in|with))?|a\/c(?:\s+no\.?)?|acct|account(?:\s+(?:no\.?|number))?|card(?:\s+no\.?)?|x{2,}|\*{2,}|customer\s+(?:id|code)|ref(?:erence)?(?:\s+no\.?)?|txn\s+id|mobile|phone)\s*[:#]?\s*$/i

  @doc "The banks shown by name when DKIM verifies, in display order."
  @spec bank_labels() :: [String.t()]
  def bank_labels, do: Enum.map(@senders, fn {_domains, _parser, label} -> label end)

  @spec parse(String.t(), keyword()) :: {:ok, result()} | {:error, :no_otp}
  def parse(body, opts \\ []) when is_binary(body) do
    {parser, label} = sender(Keyword.get(opts, :from) || "")
    text = normalize("#{Keyword.get(opts, :subject, "")}\n#{body}")

    case best_candidate(text) do
      nil -> {:error, :no_otp}
      otp -> {:ok, %{otp: otp, sender_label: label, parser: parser}}
    end
  end

  @doc """
  Strips HTML and entities and collapses whitespace. Input is capped at 256 KB and
  output at 32 KB; every pass is linear (an unclosed script/style block runs to the end).
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(text) do
    text
    |> truncate(@max_input_bytes)
    |> String.replace_invalid(" ")
    |> String.replace(~r/<(script|style)\b[^>]*>.*?(?:<\/\1>|\z)/is, " ")
    |> String.replace(~r/<[^<>]+>/, " ")
    |> decode_entities()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate(@max_text_bytes)
  end

  # Cuts at a UTF-8 boundary when the input is valid UTF-8.
  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    head = binary_part(text, 0, max)

    case :unicode.characters_to_binary(head) do
      {:incomplete, valid, _} -> valid
      _ -> head
    end
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

  @doc "Lowercased domain of an address, or nil."
  @spec sender_domain(String.t()) :: String.t() | nil
  def sender_domain(from) do
    case Regex.run(~r/@([A-Za-z0-9.-]+)/, from, capture: :all_but_first) do
      [d] -> d |> String.downcase() |> String.trim_trailing(".")
      _ -> nil
    end
  end

  defp sender(from) do
    domain = sender_domain(from)

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
    |> scored(keywords, nil, [])
    |> Enum.map(fn {score, start, len} -> {score, start, binary_part(text, start, len)} end)
    |> Enum.max_by(fn {score, start, _} -> {score, -start} end, fn -> nil end)
    |> case do
      nil -> nil
      {_, _, otp} -> otp
    end
  end

  defp excluded?(text, start, len) do
    before = text |> binary_part(max(start - 30, 0), min(start, 30)) |> drop_continuation()
    after_ = binary_part(text, start + len, min(byte_size(text) - start - len, 3))

    before =~ @separator_before or after_ =~ @separator_after or
      before =~ @amount_before or before =~ @reference_before
  end

  # The 30-byte window can start mid-character; unicode regexes reject that.
  defp drop_continuation(<<c, rest::binary>>) when c in 0x80..0xBF, do: drop_continuation(rest)
  defp drop_continuation(text), do: text

  # Candidates and keywords are both sorted by position, so one merge pass finds
  # each candidate's nearest keyword before (`prev_stop`) and after it.
  defp scored([], _keywords, _prev_stop, acc), do: acc

  defp scored([{start, len} | rest], keywords, prev_stop, acc) do
    {prev_stop, keywords} = advance(keywords, start, prev_stop)
    stop = start + len

    before =
      if prev_stop && start - prev_stop <= @before_window, do: start - prev_stop

    after_ =
      case Enum.find(keywords, fn {kw_start, _} -> kw_start >= stop end) do
        {kw_start, _} when kw_start - stop <= @after_window -> kw_start - stop
        _ -> nil
      end

    acc =
      case Enum.reject([before, after_], &is_nil/1) do
        [] -> acc
        distances -> [{score(len, Enum.min(distances)), start, len} | acc]
      end

    scored(rest, keywords, prev_stop, acc)
  end

  defp advance([{_, kw_stop} | rest], start, _prev_stop) when kw_stop <= start,
    do: advance(rest, start, kw_stop)

  defp advance(keywords, _start, prev_stop), do: {prev_stop, keywords}

  defp score(6, distance), do: 100 - distance
  defp score(_len, distance), do: 60 - distance
end
