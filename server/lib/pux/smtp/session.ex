defmodule Pux.SMTP.Session do
  @moduledoc """
  gen_smtp session callback. Parses inbound mail in memory and dispatches encrypted pushes.
  No email content is written to disk or the database.
  """
  @behaviour :gen_smtp_server_session

  alias Pux.{Inbound, Push, Records}
  alias PuxWeb.Plugs.RateLimit

  require Logger

  @impl true
  def init(hostname, _session_count, address, options) do
    state = %{
      mail_domain: Keyword.get(options, :mail_domain, "localhost"),
      max_size: Keyword.get(options, :max_size, 1_048_576),
      max_recipients: Keyword.get(options, :max_recipients, 10),
      tls?: Keyword.get(options, :tls?, false),
      require_tls?: Keyword.get(options, :require_tls?, false),
      tls_active?: false,
      classify_timeout_ms: Keyword.get(options, :classify_timeout_ms, 5_000),
      inbound_rate_limit: Keyword.get(options, :inbound_rate_limit, 20),
      inbound_rate_scale_ms: Keyword.get(options, :inbound_rate_scale_ms, 600_000),
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
  def handle_STARTTLS(state), do: %{state | tls_active?: true}

  @impl true
  def handle_MAIL(_from, %{tls?: true, require_tls?: true, tls_active?: false} = state),
    do: {:error, "530 5.7.0 Must issue a STARTTLS command first", state}

  def handle_MAIL(from, state), do: {:ok, %{state | from: from, recipients: []}}

  @impl true
  def handle_MAIL_extension(_extension, _state), do: :error

  @impl true
  def handle_RCPT(to, state) do
    without_crashing(state, fn ->
      with {:ok, token} <- extract_inbox_token(to, state.mail_domain),
           %Records.Record{} = record <- Records.get_deliverable_record_by_inbox_token(token) do
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
    end)
  end

  @impl true
  def handle_RCPT_extension(_extension, _state), do: :error

  @impl true
  def handle_DATA(_from, _to, data, state) do
    without_crashing(state, fn ->
      case classify(data, state) do
        {:ok, payload} ->
          plaintext = Jason.encode!(payload)
          Enum.each(state.recipients, &deliver(&1, plaintext, state))

        :ignore ->
          Logger.debug("SMTP: no OTP found in message")
      end

      {:ok, "250 OK", %{state | recipients: [], from: nil}}
    end)
  end

  # A crash report for this process prints its last message: the raw email or RCPT line,
  # with the OTP and inbox token. So the callbacks that can raise (database, JSON encoding)
  # reply with a temporary failure instead, and the sender retries.
  defp without_crashing(state, callback) do
    callback.()
  rescue
    e -> temporary_failure(inspect(e.__struct__), state)
  catch
    kind, _reason -> temporary_failure(inspect(kind), state)
  end

  defp temporary_failure(kind, state) do
    Logger.error("SMTP: command failed (#{kind}); replied with a temporary failure")
    {:error, "451 4.3.0 Temporary failure, try again later", state}
  end

  # Runs off the session process with a hard timeout. A task's crash report prints its
  # arguments and exit reasons can carry message content, so failures are caught inside the
  # task and only the exception type is logged.
  defp classify(data, %{from: from} = state) do
    task =
      Task.Supervisor.async_nolink(Pux.SMTP.TaskSupervisor, fn -> try_classify(data, from) end)

    case Task.yield(task, state.classify_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:failed, kind}} ->
        Logger.warning("SMTP: classification failed (#{kind}); message ignored")
        :ignore

      {:ok, result} ->
        result

      {:exit, _reason} ->
        Logger.warning("SMTP: classification failed; message ignored")
        :ignore

      nil ->
        Logger.warning("SMTP: classification timed out; message ignored")
        :ignore
    end
  end

  defp try_classify(data, from) do
    Inbound.classify(data, from)
  rescue
    e -> {:failed, inspect(e.__struct__)}
  catch
    kind, _reason -> {:failed, inspect(kind)}
  end

  defp deliver(record, plaintext, state) do
    with :ok <-
           RateLimit.allow?("record:" <> record.id,
             key: "inbound",
             limit: state.inbound_rate_limit,
             scale_ms: state.inbound_rate_scale_ms
           ),
         :ok <- Records.touch_record(record) do
      Push.deliver_to_record(record, plaintext)
    else
      {:error, :rate_limited} ->
        Logger.info("SMTP: inbound rate limit hit; delivery skipped")

      {:error, :no_devices} ->
        Logger.debug("SMTP: relay lost its last device while mail was in flight")
    end
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

  # A limit of 0 turns this off, for a listener behind a TCP proxy, where every
  # connection comes from the proxy. Keyed like the HTTP limits: IPv6 per /64.
  defp over_connection_limit?(address, options) do
    with registry when is_atom(registry) and not is_nil(registry) <- options[:registry],
         limit when is_integer(limit) and limit > 0 <- options[:max_connections_per_ip],
         pid when is_pid(pid) <- Process.whereis(registry) do
      key = RateLimit.address_key(address)
      {:ok, _} = Registry.register(registry, key, nil)
      length(Registry.lookup(registry, key)) > limit
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
