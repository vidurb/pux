defmodule PuxWeb.PageController do
  use PuxWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: "/signup")
  end
end
