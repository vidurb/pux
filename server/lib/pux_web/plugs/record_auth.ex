defmodule PuxWeb.Plugs.RecordAuth do
  @moduledoc """
  Identifies the relay from the bearer token, which is its record ID.

  A missing or malformed token and the ID of a record that doesn't exist all get the same
  401, so a response never says whether a record exists. The only timing difference is
  that a malformed token skips the lookup, which says nothing about any record.
  """
  import Plug.Conn

  alias Pux.Records
  alias Pux.Records.Record

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- valid_uuid?(token),
         %Record{id: record_id} <- Records.get_record(token) do
      # The stored ID, not the token: a UUID in another case finds the same record, and
      # must not get its own rate limit bucket.
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
end
