defmodule PuxWeb.DeviceController do
  use PuxWeb, :controller

  alias Pux.Records

  def create(conn, %{"push_token" => push_token, "platform" => platform})
      when is_binary(push_token) do
    record_id = conn.assigns.record_id

    case parse_platform(platform) do
      {:ok, platform_atom} ->
        attrs = %{
          push_token: push_token,
          platform: platform_atom
        }

        register_device_response(conn, record_id, attrs)

      {:error, :invalid_platform} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "platform must be fcm or desktop"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "push_token and platform are required"})
  end

  def delete(conn, %{"device_id" => device_id}) do
    case Records.delete_record_device(conn.assigns.record_id, device_id) do
      :ok ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  defp register_device_response(conn, record_id, attrs) do
    case Records.register_device(record_id, attrs) do
      {:ok, device} ->
        conn
        |> put_status(:created)
        |> json(%{device_id: device.id, platform: device.platform})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, :too_many_devices} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "too_many_devices"})

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "push_token must be 8 to 4096 characters"})
    end
  end

  defp parse_platform("fcm"), do: {:ok, :fcm}
  defp parse_platform("desktop"), do: {:ok, :desktop}
  defp parse_platform(_), do: {:error, :invalid_platform}
end
