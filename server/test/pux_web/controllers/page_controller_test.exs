defmodule PuxWeb.PageControllerTest do
  use PuxWeb.ConnCase, async: true

  @csp "default-src 'none'; style-src 'self'; img-src 'self'; " <>
         "base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

  describe "landing page" do
    test "renders without scripts and with a strict CSP", %{conn: conn} do
      conn = get(conn, "/")
      body = html_response(conn, 200)

      assert body =~ "sealed on the way to your phone"
      assert body =~ ~s(href="/assets/app.css")
      refute body =~ "<script"
      refute body =~ "<style"
      refute body =~ ~r/\sstyle="/
      assert get_resp_header(conn, "content-security-policy") == [@csp]
    end

    test "loads nothing from another origin", %{conn: conn} do
      body = html_response(get(conn, "/"), 200)

      refute body =~ ~r/<(img|link|source|iframe)[^>]+(src|href)="https?:(?!\/\/localhost)/i
    end

    test "sets no cookies", %{conn: conn} do
      conn = get(conn, "/")

      assert conn.resp_cookies == %{}
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "lists every bank the parser labels", %{conn: conn} do
      body = html_response(get(conn, "/"), 200)

      assert length(Pux.OtpParser.bank_labels()) == 7

      for bank <- Pux.OtpParser.bank_labels() do
        assert body =~ "<li>#{bank}</li>"
      end
    end

    test "has description, Open Graph and Twitter card tags", %{conn: conn} do
      body = html_response(get(conn, "/"), 200)

      assert body =~ ~s(<meta name="description")
      assert body =~ ~s(property="og:title")
      assert body =~ ~s(property="og:image")
      assert body =~ "/images/og-image.png"
      assert body =~ ~s(content="summary_large_image")
    end

    test "makes no claims the project can't back", %{conn: conn} do
      body = html_response(get(conn, "/"), 200)

      refute body =~ ~r/never touch/i
      refute body =~ ~r/google play|app store badge|download on the/i
      assert body =~ "any app store yet"
      assert body =~ "hasn't been tested on a real device"
      assert body =~ "Not supported for now"
    end
  end

  # The site states these numbers in words; change the copy along with the config.
  test "published retention matches the configuration" do
    # The test config turns Oban's plugins off, so read what production uses.
    config = Config.Reader.read!("config/config.exs", env: :prod)[:pux]

    assert config[:pruner][:record_ttl_days] == 90
    assert config[:pruner][:device_ttl_days] == 30
    assert config[:pruner][:delivery_ttl_minutes] == 10
    assert {Oban.Plugins.Pruner, max_age: 600} in config[Oban][:plugins]
    assert config[:smtp][:inbound_rate_limit] == 20
    assert config[:smtp][:inbound_rate_scale_ms] == 600_000
  end

  test "GET /signup redirects permanently to the landing page", %{conn: conn} do
    conn = get(conn, "/signup")

    assert conn.status == 301
    assert redirected_to(conn, 301) == "/"
  end

  describe "legal pages" do
    test "are flagged as unreviewed drafts", %{conn: conn} do
      for path <- ["/privacy", "/terms"] do
        body = html_response(get(conn, path), 200)

        assert body =~ "Draft, not yet reviewed"
        assert body =~ "privacy@vidur.xyz"
        refute body =~ "<script"
      end
    end

    test "the footer links to them", %{conn: conn} do
      body = html_response(get(conn, "/"), 200)

      assert body =~ ~s(href="/privacy")
      assert body =~ ~s(href="/terms")
    end
  end

  describe "site basics" do
    test "security.txt follows RFC 9116", %{conn: conn} do
      conn = get(conn, "/.well-known/security.txt")
      body = response(conn, 200)

      assert ["text/plain; charset=utf-8"] = get_resp_header(conn, "content-type")
      assert body =~ "Contact: https://github.com/vidurb/pux/security/advisories/new\n"
      assert body =~ "/.well-known/security.txt\n"

      [_, expires] = Regex.run(~r/^Expires: (.+)$/m, body)
      assert {:ok, at, 0} = DateTime.from_iso8601(expires)
      assert DateTime.compare(at, DateTime.utc_now()) == :gt
    end

    test "robots.txt allows the site and keeps crawlers off the API", %{conn: conn} do
      body = conn |> get("/robots.txt") |> response(200)

      assert body =~ "Allow: /\n"
      assert body =~ "Disallow: /api/\n"
    end

    test "favicons and share images are served", %{conn: conn} do
      for path <- [
            "/favicon.ico",
            "/favicon.svg",
            "/images/apple-touch-icon.png",
            "/images/og-image.png"
          ] do
        assert response(get(conn, path), 200) != ""
      end
    end
  end

  test "the stylesheet the layout links is served", %{conn: conn} do
    assert conn |> get("/assets/app.css") |> response(200) =~ "font-family"
  end

  test "JSON endpoints get the same CSP", %{conn: conn} do
    assert get_resp_header(get(conn, "/health"), "content-security-policy") == [@csp]
  end

  test "there is no LiveView socket", %{conn: conn} do
    assert get(conn, "/live/websocket").status == 404
  end
end
