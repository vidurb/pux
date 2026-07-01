defmodule PuxWeb.DeviceController do
  use PuxWeb, :controller

  alias Pux.Records

  def create(conn, %{"push_token" => push_token, "platform" => platform}) do
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

  defp register_device_response(conn, record_id, attrs) do
    case Records.register_device(record_id, attrs) do
      {:ok, device} ->
        conn
        |> put_status(:created)
        |> json(%{device_id: device.id, platform: device.platform})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: format_changeset(changeset)})
    end
  end

  defp parse_platform("fcm"), do: {:ok, :fcm}
  defp parse_platform("desktop"), do: {:ok, :desktop}
  defp parse_platform("apns"), do: {:error, :invalid_platform}
  defp parse_platform(_), do: {:error, :invalid_platform}

  defp format_changeset(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
  end
end
