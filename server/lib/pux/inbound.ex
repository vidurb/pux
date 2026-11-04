defmodule Pux.Inbound do
  @moduledoc """
  Turns a raw inbound email into the plaintext push payload, in memory.

  Payload shapes (JSON, encrypted to the record key before leaving the server):

    * `%{"type" => "otp", "otp", "sender", "sender_domain", "verified", "received_at", "parser"}`.
      `verified` means a valid DKIM signature aligns with the From domain; only then is
      `sender` a bank label, otherwise it is the From domain (or "Unknown sender").
    * `%{"type" => "forward_confirm", "code", "url", "sender", "forwarding_from", "received_at"}`
      for Gmail forwarding confirmations carrying a valid google.com DKIM signature,
      so the user can finish forwarding setup.

  `opts` are passed to `Pux.DKIM.aligned?/3`.
  """

  alias Pux.{DKIM, OtpParser}

  require Logger

  @gmail_forwarding "forwarding-noreply@google.com"

  @spec classify(binary(), String.t() | nil, keyword()) :: {:ok, map()} | :ignore
  def classify(raw, envelope_from \\ nil, opts \\ []) when is_binary(raw) do
    email = parse(raw)
    from = email.from || envelope_from || ""

    if String.downcase(from) == @gmail_forwarding do
      gmail_forward_confirm(email, raw, opts)
    else
      otp(email, raw, from, opts)
    end
  end

  defp otp(email, raw, from, opts) do
    case OtpParser.parse(email.body, from: from, subject: email.subject) do
      {:ok, result} ->
        domain = OtpParser.sender_domain(from)
        verified = DKIM.aligned?(raw, domain, opts)

        {parser, sender} =
          if verified,
            do: {result.parser, result.sender_label},
            else: {:generic, domain || "Unknown sender"}

        {:ok,
         %{
           type: "otp",
           otp: result.otp,
           sender: sender,
           sender_domain: domain,
           verified: verified,
           received_at: now(),
           parser: parser
         }}

      {:error, :no_otp} ->
        :ignore
    end
  end

  defp gmail_forward_confirm(email, raw, opts) do
    text = OtpParser.normalize(email.body)

    code =
      first_capture(~r/\(#(\d{6,12})\)/, email.subject) ||
        first_capture(~r/confirmation code:?\s*(\d{6,12})/i, text)

    url = first_capture(~r{(https://mail(?:-settings)?\.google\.com/\S+)}, text)
    forwarding_from = first_capture(~r/receive mail from\s+(\S+@\S+)/i, email.subject)

    if (code || url) && DKIM.aligned?(raw, "google.com", opts) do
      {:ok,
       %{
         type: "forward_confirm",
         code: code,
         url: url,
         sender: "Gmail",
         forwarding_from: forwarding_from,
         received_at: now()
       }}
    else
      :ignore
    end
  end

  defp first_capture(regex, text) when is_binary(text) do
    case Regex.run(regex, text, capture: :all_but_first) do
      [value | _] -> value
      _ -> nil
    end
  end

  defp first_capture(_regex, _text), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  @doc false
  def parse(raw) do
    message = Mail.parse(raw)

    %{
      from: format_address(Mail.get_from(message)),
      subject: Mail.get_subject(message) || "",
      body: extract_body(message)
    }
  rescue
    e ->
      # The exception message can echo message content; log only its type.
      Logger.warning("SMTP: failed to parse email (#{inspect(e.__struct__)})")
      %{from: nil, subject: "", body: raw}
  end

  defp extract_body(%Mail.Message{} = message) do
    text = part_body(Mail.get_text(message))
    html = part_body(Mail.get_html(message))

    cond do
      text not in [nil, ""] -> text
      html not in [nil, ""] -> html
      is_binary(message.body) -> message.body
      is_list(message.parts) -> join_parts(message.parts)
      true -> ""
    end
  end

  defp part_body(%Mail.Message{body: body}) when is_binary(body), do: body
  defp part_body(_), do: nil

  defp join_parts(parts) do
    parts
    |> Enum.map(fn
      %Mail.Message{body: body} when is_binary(body) -> body
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp format_address(nil), do: nil
  defp format_address({_, addr}), do: addr
  defp format_address(addr) when is_binary(addr), do: addr
  defp format_address([first | _]), do: format_address(first)
  defp format_address(_), do: nil
end
