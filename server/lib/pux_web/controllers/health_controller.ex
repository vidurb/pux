defmodule PuxWeb.HealthController do
  use PuxWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
