defmodule PuxWeb.RecordController do
  use PuxWeb, :controller

  alias Pux.{Crypto, Push, Records}

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

  def delete(conn, _params) do
    :ok = Records.delete_record(conn.assigns.record_id)
    send_resp(conn, :no_content, "")
  end

  @doc """
  Sends a test code to every device on the relay. See `Pux.Push.send_test_code/1`. Has its
  own per-record limit on top of the API's (`config :pux, :test_code_rate_limit`).
  """
  def test(conn, _params) do
    with %{} = record <- Records.get_record(conn.assigns.record_id),
         {:ok, %{otp: otp, devices: devices}} <- Push.send_test_code(record) do
      conn
      |> put_status(:accepted)
      |> json(%{otp: otp, devices: devices})
    else
      # Deleted since the request authenticated.
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, :no_devices} ->
        conn |> put_status(:conflict) |> json(%{error: "no_devices"})
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
