defmodule Pux.Inbound do
  @moduledoc """
  Turns a raw inbound email into the plaintext push payload, in memory.

  Payload shapes (JSON, encrypted to the record key before leaving the server):

    * `%{"type" => "otp", "otp", "sender", "received_at", "parser"}`
    * `%{"type" => "forward_confirm", "code", "url", "sender", "forwarding_from", "received_at"}`
      for mail-provider forwarding confirmations, so the user can finish forwarding setup.
  """

  alias Pux.OtpParser

  require Logger

  @gmail_forwarding "forwarding-noreply@google.com"

  @spec classify(binary(), String.t() | nil) :: {:ok, map()} | :ignore
  def classify(raw, envelope_from \\ nil) when is_binary(raw) do
    email = parse(raw)
    from = email.from || envelope_from || ""

    cond do
      String.downcase(from) == @gmail_forwarding ->
        gmail_forward_confirm(email)

      true ->
        case OtpParser.parse(email.body, from: from, subject: email.subject) do
          {:ok, result} ->
            {:ok,
             %{
               type: "otp",
               otp: result.otp,
               sender: result.sender_label,
               received_at: now(),
               parser: result.parser
             }}

          {:error, :no_otp} ->
            :ignore
        end
    end
  end

  defp gmail_forward_confirm(email) do
    text = OtpParser.normalize(email.body)

    code =
      first_capture(~r/\(#(\d{6,12})\)/, email.subject) ||
        first_capture(~r/confirmation code:?\s*(\d{6,12})/i, text)

    url = first_capture(~r{(https://mail(?:-settings)?\.google\.com/\S+)}, text)
    forwarding_from = first_capture(~r/receive mail from\s+(\S+@\S+)/i, email.subject)

    if code || url do
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
      Logger.warning("SMTP: failed to parse email: #{Exception.message(e)}")
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
