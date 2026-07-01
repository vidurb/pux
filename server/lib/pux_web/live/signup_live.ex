defmodule PuxWeb.SignupLive do
  use PuxWeb, :live_view

  alias Pux.Records

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, enrollment: nil, qr_svg: nil)}
  end

  @impl true
  def handle_event("create", _params, socket) do
    client_key = client_ip(socket)

    rate_opts = [
      key: "record_create",
      scale_ms: rate_limit_config(:record_create_scale_ms, 60_000),
      limit: rate_limit_config(:record_create_limit, 10)
    ]

    case PuxWeb.Plugs.RateLimit.allow?(client_key, rate_opts) do
      :ok ->
        create_record(socket)

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, "Too many signup attempts. Please try again later.")}
    end
  end

  defp create_record(socket) do
    case Records.create_record() do
      {:ok, enrollment} ->
        qr_svg =
          enrollment.qr_payload
          |> Jason.encode!()
          |> EQRCode.encode()
          |> EQRCode.svg(width: 240)

        {:noreply,
         socket
         |> assign(:enrollment, enrollment)
         |> assign(:qr_svg, qr_svg)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not create record. Please try again.")}
    end
  end

  defp client_ip(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: address} -> address |> :inet.ntoa() |> to_string()
      _ -> "unknown"
    end
  end

  defp rate_limit_config(key, default) do
    Application.get_env(:pux, :rate_limit, []) |> Keyword.get(key, default)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="signup">
      <h1>pux</h1>
      <p>Encrypted OTP relay. No accounts. No stored emails.</p>

      <%= if @enrollment do %>
        <section class="enrollment">
          <h2>Scan with the pux app</h2>
          <p class="warning">
            This QR contains your private key. It is shown once and never stored on the server.
          </p>
          <div class="qr">
            <%= raw @qr_svg %>
          </div>
          <dl>
            <dt>Inbox address</dt>
            <dd><code>{@enrollment.inbox_address}</code></dd>
            <dt>Record ID</dt>
            <dd><code>{@enrollment.record_id}</code></dd>
          </dl>
          <p>
            Set up email forwarding from your bank OTP address to
            <strong>{@enrollment.inbox_address}</strong>.
          </p>
        </section>
      <% else %>
        <button phx-click="create" class="primary">Create relay</button>
      <% end %>
    </div>
    """
  end
end
