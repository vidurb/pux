defmodule Pux.SMTP.Session do
  @moduledoc """
  gen_smtp session callback. Parses inbound mail in memory and dispatches encrypted pushes.
  No email content is written to disk or the database.
  """
  @behaviour :gen_smtp_server_session

  alias Pux.{OtpParser, Push, Records}

  require Logger

  @impl true
  def init(_hostname, _session_count, _address, options) do
    mail_domain =
      options
      |> Keyword.get(:mail_domain, "localhost")
      |> String.downcase()

    {:ok, "220 pux ready", %{recipients: [], from: nil, mail_domain: mail_domain}}
  end

  @impl true
  def handle_HELO(_hostname, state), do: {:ok, state}

  @impl true
  def handle_EHLO(_hostname, _extensions, state), do: {:ok, [], state}

  @impl true
  def handle_MAIL(from, state) do
    {:ok, %{state | from: from}}
  end

  @impl true
  def handle_RCPT(to, %{mail_domain: mail_domain} = state) do
    case extract_inbox_token(to, mail_domain) do
      {:ok, token} -> {:ok, %{state | recipients: [token | state.recipients]}}
      :error -> {:error, "550 Recipient rejected", state}
    end
  end

  @impl true
  def handle_DATA(_from, _to, data, state) do
    mail_domain = Application.get_env(:pux, :smtp)[:mail_domain] || "localhost"
    sender = state.from

    Enum.each(state.recipients, fn inbox_token ->
      process_message(inbox_token, data, sender, mail_domain)
    end)

    {:ok, "250 OK", %{state | recipients: [], from: nil}}
  end

  @impl true
  def handle_RSET(state), do: %{state | recipients: [], from: nil}

  @impl true
  def handle_other(_verb, _args, state), do: {["500 Error: command not recognized"], state}

  @impl true
  def terminate(_reason, state), do: {:ok, :normal, state}

  defp process_message(inbox_token, raw_email, from, _mail_domain) do
    with %Records.Record{} = record <- Records.get_record_by_inbox_token(inbox_token),
         {:ok, parsed} <- parse_email(raw_email),
         {:ok, otp_result} <-
           OtpParser.parse(parsed.body, from: parsed.from || from, subject: parsed.subject) do
      Records.touch_record!(record)

      payload =
        Jason.encode!(%{
          otp: otp_result.otp,
          sender: otp_result.sender_label,
          received_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          parser: otp_result.parser
        })

      Push.deliver_to_record(record, payload)
    else
      nil ->
        Logger.debug("SMTP: unknown inbox token #{inbox_token}")

      {:error, :no_otp} ->
        Logger.debug("SMTP: no OTP found for inbox #{inbox_token}")

      {:error, reason} ->
        Logger.warning("SMTP: failed to process message for #{inbox_token}: #{inspect(reason)}")
    end
  end

  defp parse_email(raw) when is_binary(raw) do
    message = Mail.parse(raw)

    {:ok,
     %{
       from: format_address(Mail.get_from(message)),
       subject: Mail.get_subject(message) || "",
       body: extract_body(message)
     }}
  rescue
    e ->
      Logger.warning("SMTP: failed to parse email: #{Exception.message(e)}")
      {:ok, %{from: nil, subject: "", body: raw}}
  end

  defp extract_body(%Mail.Message{} = message) do
    case Mail.get_text(message) do
      %Mail.Message{body: body} when is_binary(body) ->
        body

      _ ->
        case message.body do
          body when is_binary(body) -> body
          parts when is_list(parts) -> join_parts(parts)
          _ -> ""
        end
    end
  end

  defp join_parts(parts) do
    parts
    |> Enum.map(fn
      {_, content} when is_binary(content) -> content
      content when is_binary(content) -> content
      %Mail.Message{body: body} when is_binary(body) -> body
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp format_address(nil), do: nil
  defp format_address({_, addr}), do: addr
  defp format_address(addr) when is_binary(addr), do: addr
  defp format_address(addrs) when is_list(addrs), do: addrs |> List.first() |> format_address()

  defp extract_inbox_token(recipient, mail_domain) when is_binary(recipient) do
    case String.split(recipient, "@", parts: 2) do
      [token, domain] when byte_size(token) >= 8 ->
        if String.downcase(domain) == mail_domain do
          {:ok, String.downcase(token)}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp extract_inbox_token({_, recipient}, mail_domain),
    do: extract_inbox_token(recipient, mail_domain)

  defp extract_inbox_token(_, _), do: :error
end
