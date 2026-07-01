defmodule PuxWeb.RecordController do
  use PuxWeb, :controller

  alias Pux.{Crypto, Records}

  def create(conn, params) do
    with {:ok, public_key} <- decode_public_key(params["public_key"]),
         {:ok, enrollment} <- Records.create_record(public_key) do
      conn
      |> put_status(:created)
      |> json(%{
        record_id: enrollment.record_id,
        inbox_address: enrollment.inbox_address,
        public_key: enrollment.public_key
      })
    else
      {:error, :invalid_public_key} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid public_key"})

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "could not create record"})
    end
  end

  defp decode_public_key(encoded) when is_binary(encoded) do
    case Crypto.decode_key(encoded) do
      {:ok, public_key} -> {:ok, public_key}
      {:error, :invalid} -> {:error, :invalid_public_key}
    end
  end

  defp decode_public_key(_), do: {:error, :invalid_public_key}
end
