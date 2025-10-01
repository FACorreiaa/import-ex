defmodule Financex.Application do
  @moduledoc """
  OTP Application entry point for the Financex import service.

  This module implements the Application behaviour and is responsible for starting
  the supervision tree when the application starts.

  ## Supervision Tree

  The application starts the following processes:

  1. **Task.Supervisor** (`Financex.TaskSupervisor`)
     - Supervises all import job tasks
     - Uses `:temporary` restart strategy (failed tasks are not restarted)
     - Allows jobs to run concurrently without blocking the scheduler

  2. **Financex.Scheduler** (conditional)
     - Manages cron-like scheduling of import jobs
     - Only started if configuration is successfully loaded
     - Handles both immediate and scheduled execution modes

  ## Configuration Loading

  The application attempts to load configuration on startup:
  - If configuration loads successfully, the scheduler is started
  - If configuration fails, only the task supervisor is started
  - Configuration errors are logged but don't prevent the app from starting

  ## Startup Modes

  ### Scheduled Mode (default)
  When `RUN_IMMEDIATELY` env var is not set or is not "1":
  - Jobs are scheduled according to cron schedule
  - Each client runs daily at its assigned time
  - First client at 22:00, subsequent clients staggered by 15 minutes

  ### Immediate Mode
  When `RUN_IMMEDIATELY=1`:
  - All jobs run immediately on startup
  - No recurring schedule is set up
  - Useful for testing or manual one-off imports

  ## Graceful Shutdown

  The application handles shutdown signals gracefully:
  - SIGINT (Ctrl+C) and SIGTERM are caught
  - Running jobs are allowed to complete or timeout
  - Scheduler stops accepting new jobs
  - Supervision tree is terminated cleanly

  ## Usage

  The application is started automatically when running:

      # Start as a daemon
      mix run --no-halt

      # Start in interactive mode
      iex -S mix

      # Run with immediate mode
      RUN_IMMEDIATELY=1 mix run --no-halt

  ## Manual Start

  For testing or development:

      {:ok, pid} = Financex.Application.start(:normal, [])
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Financex application")

    children = build_children()

    opts = [strategy: :one_for_one, name: Financex.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("Financex application started successfully")
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start Financex application", error: inspect(reason))
        error
    end
  end

  @impl true
  def stop(_state) do
    Logger.info("Stopping Financex application")
    :ok
  end

  ## Private Functions

  # Builds the list of child processes for the supervision tree
  @spec build_children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  defp build_children do
    # Always start the task supervisor
    base_children = [
      {Task.Supervisor, name: Financex.TaskSupervisor}
    ]

    # Try to load config and add scheduler if successful
    case Financex.Import.init_config() do
      {:ok, config} ->
        Logger.info("Configuration loaded, adding scheduler to supervision tree")
        base_children ++ [{Financex.Scheduler, config}]

      {:error, reason} ->
        Logger.warning(
          "Failed to load configuration, scheduler will not be started. " <>
            "You can still run imports manually via Mix tasks.",
          error: inspect(reason)
        )

        base_children
    end
  end
end
