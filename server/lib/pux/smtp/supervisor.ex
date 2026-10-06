defmodule Pux.SMTP.Supervisor do
  @moduledoc false
  use Supervisor

  @registry Pux.SMTP.Registry

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :duplicate, name: @registry},
      :gen_smtp_server.child_spec(:pux_smtp, Pux.SMTP.Session, server_options())
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Listener options for `:gen_smtp_server`. Everything the session callback needs
  must go under `sessionoptions.callbackoptions`; gen_smtp passes only that to `init/4`.
  """
  def server_options(smtp_config \\ Application.get_env(:pux, :smtp, [])) do
    port = Keyword.get(smtp_config, :port, 2525)
    domain = Keyword.get(smtp_config, :domain, "localhost")
    certfile = Keyword.get(smtp_config, :tls_certfile)
    keyfile = Keyword.get(smtp_config, :tls_keyfile)
    tls? = is_binary(certfile) and is_binary(keyfile)

    callback_options = [
      mail_domain: smtp_config |> Keyword.get(:mail_domain, domain) |> String.downcase(),
      max_size: Keyword.get(smtp_config, :max_message_size, 1_048_576),
      max_recipients: Keyword.get(smtp_config, :max_recipients, 10),
      max_connections_per_ip: Keyword.get(smtp_config, :max_connections_per_ip, 5),
      tls?: tls?,
      registry: @registry
    ]

    session_options =
      [callbackoptions: callback_options] ++
        if tls?, do: [tls_options: [certfile: certfile, keyfile: keyfile]], else: []

    [
      port: port,
      domain: domain,
      sessionoptions: session_options,
      ranch_opts: %{
        max_connections: Keyword.get(smtp_config, :max_connections, 100),
        num_acceptors: 10
      }
    ]
  end
end
