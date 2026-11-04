defmodule PuxWeb.PageController do
  use PuxWeb, :controller

  alias Pux.OtpParser

  @description "pux turns the OTP emails your bank sends into end-to-end encrypted push " <>
                 "notifications. No accounts, no stored mail, open source."

  def home(conn, _params) do
    conn
    |> meta("pux: encrypted OTP relay", @description)
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
