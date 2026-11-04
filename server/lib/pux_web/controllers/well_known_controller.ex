defmodule PuxWeb.WellKnownController do
  use PuxWeb, :controller

  @contact "https://github.com/vidurb/pux/security/advisories/new"
  @policy "https://github.com/vidurb/pux/blob/main/SECURITY.md"
  @one_year 365 * 86_400

  # RFC 9116. Generated so that Expires can't lapse on an instance nobody redeploys.
  def security_txt(conn, _params) do
    expires =
      DateTime.utc_now()
      |> DateTime.add(@one_year, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    text(conn, """
    Contact: #{@contact}
    Expires: #{expires}
    Preferred-Languages: en
    Canonical: #{PuxWeb.Endpoint.url()}/.well-known/security.txt
    Policy: #{@policy}
    """)
  end
end
