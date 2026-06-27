defmodule PuxWeb.SignupLive do
  use PuxWeb, :live_view

  alias Pux.Records

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, enrollment: nil, qr_svg: nil)}
  end

  @impl true
  def handle_event("create", _params, socket) do
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

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create record: #{inspect(reason)}")}
    end
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
          <div class="qr" phx-no-curriculum>
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
