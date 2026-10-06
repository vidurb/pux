defmodule PuxWeb.HealthController do
  use PuxWeb, :controller

  alias Pux.Repo

  def show(conn, _params) do
    case Repo.query("SELECT 1") do
      {:ok, _} ->
        json(conn, %{status: "ok"})

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "error"})
    end
  end
end
