defmodule PuxWeb.PageControllerTest do
  use PuxWeb.ConnCase, async: true

  @csp "default-src 'none'; style-src 'self'; img-src 'self'; " <>
         "base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

  test "GET / redirects to /signup", %{conn: conn} do
    assert redirected_to(get(conn, "/")) == "/signup"
  end

  test "GET /signup renders without LiveView JS and with a strict CSP", %{conn: conn} do
    conn = get(conn, "/signup")
    body = html_response(conn, 200)

    assert body =~ "Encrypted OTP relay"
    assert body =~ ~s(href="/assets/app.css")
    refute body =~ "app.js"
    refute body =~ "<style"
    assert get_resp_header(conn, "content-security-policy") == [@csp]
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
