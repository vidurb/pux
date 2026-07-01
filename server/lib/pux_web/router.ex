defmodule PuxWeb.Router do
  use PuxWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PuxWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :rate_limited_create do
    plug :accepts, ["json"]
    plug PuxWeb.Plugs.RateLimit, key: "record_create"
  end

  pipeline :record_auth do
    plug PuxWeb.Plugs.RecordAuth
  end

  scope "/", PuxWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/signup", SignupLive, :new
  end

  scope "/api/v1", PuxWeb do
    pipe_through :rate_limited_create

    post "/records", RecordController, :create
  end

  scope "/api/v1", PuxWeb do
    pipe_through [:api, :record_auth]

    post "/records/:id/devices", DeviceController, :create
  end

  scope "/", PuxWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end
end
