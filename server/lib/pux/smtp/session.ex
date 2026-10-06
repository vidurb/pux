defmodule Pux.SMTP.Session do
  @moduledoc """
  gen_smtp session callback. Parses inbound mail in memory and dispatches encrypted pushes.
  No email content is written to disk or the database.
  """
  @behaviour :gen_smtp_server_session

  alias Pux.{Inbound, Push, Records}

  require Logger

  @impl true
  def init(hostname, _session_count, address, options) do
    state = %{
      mail_domain: Keyword.get(options, :mail_domain, "localhost"),
      max_size: Keyword.get(options, :max_size, 1_048_576),
      max_recipients: Keyword.get(options, :max_recipients, 10),
      tls?: Keyword.get(options, :tls?, false),
      from: nil,
      recipients: []
    }

    if over_connection_limit?(address, options) do
      {:stop, :normal, "421 4.7.0 Too many connections from your host"}
    else
      {:ok, "#{hostname} ESMTP pux", state}
    end
  end

  @impl true
  def handle_HELO(_hostname, state), do: {:ok, state.max_size, state}

  @impl true
  def handle_EHLO(_hostname, extensions, state) do
    extensions =
      List.keystore(extensions, ~c"SIZE", 0, {~c"SIZE", Integer.to_charlist(state.max_size)})

    extensions = if state.tls?, do: [{~c"STARTTLS", true} | extensions], else: extensions
    {:ok, extensions, state}
  end

  @impl true
  def handle_STARTTLS(state), do: state

  @impl true
  def handle_MAIL(from, state), do: {:ok, %{state | from: from, recipients: []}}

  @impl true
  def handle_MAIL_extension(_extension, _state), do: :error

  @impl true
  def handle_RCPT(to, state) do
    with {:ok, token} <- extract_inbox_token(to, state.mail_domain),
         %Records.Record{} = record <- Records.get_record_by_inbox_token(token) do
      cond do
        Enum.any?(state.recipients, &(&1.id == record.id)) ->
          {:ok, state}

        length(state.recipients) >= state.max_recipients ->
          {:error, "452 4.5.3 Too many recipients", state}

        true ->
          {:ok, %{state | recipients: [record | state.recipients]}}
      end
    else
      _ -> {:error, "550 5.1.1 Recipient rejected", state}
    end
  end

  @impl true
  def handle_RCPT_extension(_extension, _state), do: :error

  @impl true
  def handle_DATA(_from, _to, data, state) do
    case Inbound.classify(data, state.from) do
      {:ok, payload} ->
        plaintext = Jason.encode!(payload)

        Enum.each(state.recipients, fn record ->
          Records.touch_record!(record)
          Push.deliver_to_record(record, plaintext)
        end)

      :ignore ->
        Logger.debug("SMTP: no OTP found in message")
    end

    {:ok, "250 OK", %{state | recipients: [], from: nil}}
  end

  @impl true
  def handle_RSET(state), do: %{state | recipients: [], from: nil}

  @impl true
  def handle_VRFY(_address, state), do: {:error, "252 VRFY disabled", state}

  @impl true
  def handle_other(_verb, _args, state), do: {["500 Error: command not recognized"], state}

  @impl true
  def code_change(_old, state, _extra), do: {:ok, state}

  @impl true
  def terminate(reason, state), do: {:ok, reason, state}

  defp over_connection_limit?(address, options) do
    with registry when is_atom(registry) and not is_nil(registry) <- options[:registry],
         limit when is_integer(limit) <- options[:max_connections_per_ip],
         pid when is_pid(pid) <- Process.whereis(registry) do
      {:ok, _} = Registry.register(registry, address, nil)
      length(Registry.lookup(registry, address)) > limit
    else
      _ -> false
    end
  end

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

  defp extract_inbox_token(_, _), do: :error
end
