defmodule PuxWeb.ErrorHTMLTest do
  use PuxWeb.ConnCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "an unknown page gets the branded 404 in the site layout", %{conn: conn} do
    body = conn |> get("/no-such-page") |> html_response(404)

    assert body =~ "<title>Page not found | pux</title>"
    assert body =~ ~s(<meta name="robots" content="noindex")
    assert body =~ ~s(href="/assets/app.css")
    assert body =~ ~s(class="site-header")
    assert body =~ ~s(class="site-footer")
    assert body =~ ~s(href="/privacy")
    refute body =~ "<script"
  end

  test "server errors get the branded 500 page", %{conn: conn} do
    body = render_to_string(PuxWeb.ErrorHTML, "500", "html", conn: conn)

    assert body =~ "<title>Something went wrong | pux</title>"
    assert body =~ ~s(class="site-header")
    refute body =~ "<script"
  end

  test "other statuses fall back to the status message" do
    assert render_to_string(PuxWeb.ErrorHTML, "418", "html", []) == "I&#39;m a teapot"
  end
end
