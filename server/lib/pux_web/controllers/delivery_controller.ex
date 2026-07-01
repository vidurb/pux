defmodule PuxWeb.DeliveryController do
  use PuxWeb, :controller

  alias Pux.Deliveries

  def index(conn, _params) do
    record_id = conn.assigns.record_id

    deliveries =
      record_id
      |> Deliveries.list_pending()
      |> Enum.map(fn pending ->
        %{
          delivery_id: pending.id,
          envelope: pending.envelope
        }
      end)

    json(conn, %{deliveries: deliveries})
  end

  def delete(conn, %{"delivery_id" => delivery_id}) do
    record_id = conn.assigns.record_id

    case Deliveries.ack_pending(record_id, delivery_id) do
      :ok ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end
end
