defmodule Pux.SMTP.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    smtp_config = Application.get_env(:pux, :smtp, [])
    port = Keyword.get(smtp_config, :port, 2525)
    domain = Keyword.get(smtp_config, :domain, "localhost")
    mail_domain = Keyword.get(smtp_config, :mail_domain, domain)
    max_size = Keyword.get(smtp_config, :max_message_size, 1_048_576)

    session_options = [mail_domain: mail_domain]

    server_options =
      [
        port: port,
        domain: domain,
        sessionoptions: session_options,
        maxsize: max_size
      ]
      |> maybe_add_tls(smtp_config)

    children = [
      %{
        id: :pux_smtp,
        start: {:gen_smtp_server, :start, [Pux.SMTP.Session, server_options]},
        restart: :permanent,
        shutdown: 5000,
        type: :worker
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp maybe_add_tls(opts, smtp_config) do
    certfile = Keyword.get(smtp_config, :tls_certfile)
    keyfile = Keyword.get(smtp_config, :tls_keyfile)

    if is_binary(certfile) and is_binary(keyfile) do
      Keyword.merge(opts, certfile: certfile, keyfile: keyfile)
    else
      opts
    end
  end
end
