defmodule RealtimeWeb.Router do
  use RealtimeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug CORSPlug
    plug :accepts, ["json"]
  end

  scope "/", RealtimeWeb do
    pipe_through :browser

    get "/", PageController, :index
  end

  scope "/api", RealtimeWeb do
    pipe_through :api

    resources "/workflows", WorkflowController do
      resources "/executions", ExecutionController, only: [:index, :create, :show, :delete]
    end
  end

  if Mix.env() == :dev do
    forward "/sent_emails", Bamboo.SentEmailViewerPlug
  end
end
