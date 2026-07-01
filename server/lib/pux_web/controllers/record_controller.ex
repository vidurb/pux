defmodule PuxWeb.RecordController do
  use PuxWeb, :controller

  alias Pux.Records

  def create(conn, _params) do
    case Records.create_record() do
      {:ok, enrollment} ->
        conn
        |> put_status(:created)
        |> json(%{
          record_id: enrollment.record_id,
          inbox_address: enrollment.inbox_address,
          public_key: enrollment.public_key,
          private_key: enrollment.private_key,
          qr_payload: enrollment.qr_payload
        })

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "could not create record"})
    end
  end
end
