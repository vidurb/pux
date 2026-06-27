defmodule PuxWeb.Plugs.RecordAuth do
  @moduledoc """
  Authorizes requests using the record UUID as a bearer token.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- valid_uuid?(token),
         record_id when is_binary(record_id) <- conn.path_params["id"],
         true <- secure_compare(token, record_id) do
      assign(conn, :record_id, record_id)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "unauthorized"})
        |> halt()
    end
  end

  defp valid_uuid?(value) do
    match?(
      <<_::128>>,
      case Ecto.UUID.dump(value) do
        {:ok, bin} -> bin
        :error -> <<>>
      end
    )
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end
end
