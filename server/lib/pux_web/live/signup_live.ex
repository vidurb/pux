defmodule PuxWeb.SignupLive do
  use PuxWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="signup">
      <h1>pux</h1>
      <p>Encrypted OTP relay. No accounts. No stored emails.</p>

      <section class="security">
        <h2>How it stays private</h2>
        <ul>
          <li>
            <strong>Client-side keys.</strong>
            Your encryption keypair is generated on your phone. The private key never leaves your device.
          </li>
          <li>
            <strong>Public key only.</strong>
            The server stores your public key so it can encrypt OTPs for you. It cannot decrypt them.
          </li>
          <li>
            <strong>Sealed boxes.</strong>
            OTP payloads are encrypted with libsodium sealed boxes before push delivery.
          </li>
          <li>
            <strong>No stored mail.</strong>
            Inbound email is parsed in memory and discarded. OTPs are never written to disk or the database.
          </li>
          <li>
            <strong>No accounts.</strong>
            A record ID is your only credential. Add more devices by scanning a QR from an enrolled phone.
          </li>
        </ul>
      </section>

      <section class="setup">
        <h2>Get started</h2>
        <ol>
          <li>Install the pux Android app.</li>
          <li>Open the app and tap <strong>Create new relay</strong>.</li>
          <li>Copy your inbox address and set up email forwarding from your bank OTP address.</li>
          <li>Grant notification permission when prompted.</li>
        </ol>
        <p class="note">
          Enrollment happens entirely in the mobile app. The server never sees your private key.
        </p>
      </section>

      <section class="smtp">
        <h2>SMTP relay</h2>
        <p>
          This server accepts inbound mail for <code>*@pux.vidur.xyz</code> (or your configured mail domain).
          Only recipients with a valid inbox token are accepted. Messages are size-limited and processed in memory.
        </p>
      </section>
    </div>
    """
  end
end
