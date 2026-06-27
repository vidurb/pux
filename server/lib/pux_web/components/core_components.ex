defmodule PuxWeb.CoreComponents do
  use Phoenix.Component

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <%= for {kind, message} <- @flash do %>
      <p class={"flash flash-#{kind}"}><%= message %></p>
    <% end %>
    """
  end
end
