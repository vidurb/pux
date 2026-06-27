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

  children = [
    %{
      id: :pux_smtp,
      start:
        {:gen_smtp_server, :start,
         [Pux.SMTP.Session, [port: port, domain: domain, sessionoptions: []]]},
      restart: :permanent,
      shutdown: 5000,
      type: :worker
    }
  ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
