defmodule PuxWeb.PageController do
  use PuxWeb, :controller

  alias Pux.OtpParser

  @description "Get your bank OTPs on your computer and every phone you add, over Wi-Fi " <>
                 "or any internet connection, even when your phone has no signal. " <>
                 "End-to-end encrypted and open source."

  def home(conn, _params) do
    conn
    |> meta("pux: bank OTPs on every device, even with no signal", @description)
    |> render(:home, banks: OtpParser.bank_labels())
  end

  def privacy(conn, _params) do
    conn
    |> meta("Privacy policy | pux", "What the pux service and apps collect, keep and share.")
    |> render(:privacy)
  end

  def terms(conn, _params) do
    conn
    |> meta("Terms of service | pux", "The terms for using the hosted pux service and apps.")
    |> render(:terms)
  end

  def signup(conn, _params) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(to: "/")
  end

  defp meta(conn, title, description) do
    merge_assigns(conn, page_title: title, description: description)
  end
end
