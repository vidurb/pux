defmodule PuxWeb.DeviceController do
  use PuxWeb, :controller

  alias Pux.Records

  def create(conn, %{"push_token" => push_token, "platform" => platform}) do
    record_id = conn.assigns.record_id

    attrs = %{
      push_token: push_token,
      platform: parse_platform(platform)
    }

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

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "push_token and platform are required"})
  end

  defp parse_platform("fcm"), do: :fcm
  defp parse_platform("apns"), do: :apns
  defp parse_platform(_), do: :fcm

  defp format_changeset(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
  end
end
