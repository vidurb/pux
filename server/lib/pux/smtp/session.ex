defmodule Pux.SMTP.Session do
  @moduledoc """
  gen_smtp session callback. Parses inbound mail in memory and dispatches encrypted pushes.
  No email content is written to disk or the database.
  """
  @behaviour :gen_smtp_server_session

  alias Pux.{OtpParser, Push, Records}

  require Logger

  @impl true
  def init(_hostname, _session, _options) do
    {:ok, %{recipients: [], from: nil}}
  end

  @impl true
  def handle_MAIL(from, _email, state) do
    {:ok, %{state | from: from}}
  end

  @impl true
  def handle_RCPT(to, state) do
    case extract_inbox_token(to) do
      {:ok, token} -> {:ok, %{state | recipients: [token | state.recipients]}}
      :error -> {:error, "550 Recipient rejected"}
    end
  end

  @impl true
  def handle_DATA(data, _session, state) do
    mail_domain = Application.get_env(:pux, :smtp)[:mail_domain] || "localhost"

    Enum.each(state.recipients, fn inbox_token ->
      process_message(inbox_token, data, state.from, mail_domain)
    end)

    :ok
  end

  @impl true
  def handle_RSET(state), do: {:ok, %{state | recipients: [], from: nil}}

  @impl true
  def handle_other(_payload, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

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
    case Mail.read(raw) do
      {:ok, %Mail.Message{} = message} ->
        {:ok,
         %{
           from: format_address(message.from),
           subject: message.subject || "",
           body: extract_body(message)
         }}

      {:error, _} ->
        {:ok, %{from: nil, subject: "", body: raw}}
    end
  end

  defp extract_body(%Mail.Message{body: body}) when is_binary(body), do: body

  defp extract_body(%Mail.Message{body: parts}) when is_list(parts) do
    parts
    |> Enum.map(fn
      {_, content} when is_binary(content) -> content
      content when is_binary(content) -> content
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp extract_body(_), do: ""

  defp format_address(nil), do: nil
  defp format_address({_, addr}), do: addr
  defp format_address(addr) when is_binary(addr), do: addr
  defp format_address(addrs) when is_list(addrs), do: addrs |> List.first() |> format_address()

  defp extract_inbox_token(recipient) when is_binary(recipient) do
    case String.split(recipient, "@", parts: 2) do
      [token, _domain] when byte_size(token) >= 8 -> {:ok, String.downcase(token)}
      _ -> :error
    end
  end

  defp extract_inbox_token({_, recipient}), do: extract_inbox_token(recipient)
  defp extract_inbox_token(_), do: :error
end
