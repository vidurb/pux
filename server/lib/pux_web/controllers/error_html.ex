defmodule PuxWeb.ErrorHTML do
  @moduledoc """
  Error pages for browsers, drawn in the site layout so they match the rest of pux.

  Phoenix renders these with no layout, so each page wraps itself in the root layout.
  Anything other than a 404 or 500 falls back to the plain status message.
  """
  use PuxWeb, :html

  def render("404.html", assigns) do
    error_page(
      assigns,
      "Page not found",
      "There's nothing at this address. The link may be wrong, or the page may have moved."
    )
  end

  def render("500.html", assigns) do
    error_page(
      assigns,
      "Something went wrong",
      "The server hit an error. Try again in a moment, and if it keeps happening, open an issue on GitHub."
    )
  end

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  defp error_page(assigns, heading, message) do
    assigns =
      Map.merge(assigns, %{
        heading: heading,
        message: message,
        page_title: "#{heading} | pux",
        noindex: true
      })

    PuxWeb.Layouts.root(Map.put(assigns, :inner_content, content(assigns)))
  end

  defp content(assigns) do
    ~H"""
    <section class="section">
      <div class="wrap wrap--narrow error-page">
        <h1>{@heading}</h1>
        <p class="section-lede">{@message}</p>
        <p class="actions">
          <a class="button button--solid" href="/">Go to the home page</a>
          <a class="button" href="https://github.com/vidurb/pux/issues">Report a problem</a>
        </p>
      </div>
    </section>
    """
  end
end
