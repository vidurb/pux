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
    plug PuxWeb.Plugs.RecordRateLimit
  end

  scope "/", PuxWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/privacy", PageController, :privacy
    get "/terms", PageController, :terms
    # The landing page used to live here; keep old links working.
    get "/signup", PageController, :signup
  end

  scope "/.well-known", PuxWeb do
    get "/security.txt", WellKnownController, :security_txt
  end

  scope "/api/v1", PuxWeb do
    pipe_through :rate_limited_create

    post "/records", RecordController, :create
  end

  scope "/api/v1", PuxWeb do
    pipe_through [:api, :record_auth]

    # The relay comes from the bearer token. Its ID must stay out of these paths, since
    # reverse proxies log them.
    delete "/record", RecordController, :delete
    post "/record/devices", DeviceController, :create
    delete "/record/devices/:device_id", DeviceController, :delete
    get "/record/deliveries", DeliveryController, :index
    delete "/record/deliveries/:delivery_id", DeliveryController, :delete
  end

  scope "/", PuxWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end
end
