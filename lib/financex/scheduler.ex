defmodule Financex.Scheduler do
  @moduledoc """
  Cron-based scheduler for RealData import jobs.

  This module manages the scheduling of import jobs for multiple RealData clients.
  It implements a staggered scheduling strategy to avoid overwhelming the servers
  by running all clients simultaneously.

  ## Scheduling Strategy

  Jobs are scheduled daily with the following logic:
  - First job starts at 22:00 (10 PM)
  - Each subsequent client is delayed by 15 minutes
  - Jobs wrap around to the next hour after 60 minutes

  ### Examples

  - Client 0: 22:00 (10:00 PM)
  - Client 1: 22:15 (10:15 PM)
  - Client 2: 22:30 (10:30 PM)
  - Client 3: 22:45 (10:45 PM)
  - Client 4: 23:00 (11:00 PM)
  - Client 5: 23:15 (11:15 PM)
  - etc.

  ## Job Execution

  Each job:
  1. Has a 30-minute timeout
  2. Retries up to 10 times on failure
  3. Waits 15 minutes between retries
  4. Logs all attempts and outcomes

  ## Usage

  The scheduler is typically started as part of the application supervision tree:

      children = [
        {Financex.Scheduler, config}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  Or manually:

      {:ok, pid} = Financex.Scheduler.start_link(config)
  """

  use GenServer
  require Logger

  alias Financex.Config
  alias Financex.Config.RealDataClientConfig
  alias Financex.Worker

  @type state :: %{
          config: Config.t(),
          schedulers: [pid()],
          run_immediately: boolean()
        }

  # Constants matching the Go implementation
  @one_day_hours 24
  @one_hour_minutes 60
  @first_job_start_hour 22
  @client_run_delay_minutes 15

  ## Client API

  @doc """
  Starts the scheduler GenServer.

  ## Parameters
  - `config` - Validated AppConfig struct with all client configurations

  ## Options
  - `:name` - Optional name for the GenServer (defaults to module name)

  ## Returns
  - `{:ok, pid}` on success
  - `{:error, reason}` on failure
  """
  @spec start_link(Config.t(), keyword()) :: GenServer.on_start()
  def start_link(config, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, config, name: name)
  end

  @doc """
  Stops the scheduler gracefully.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server \\ __MODULE__) do
    GenServer.stop(server)
  end

  ## Server Callbacks

  @impl true
  def init(%Config{} = config) do
    Logger.info("Initializing scheduler with #{length(config.realdata_clients)} client(s)")

    # Schedule initialization for after the GenServer starts
    send(self(), :schedule_jobs)

    {:ok,
     %{
       config: config,
       schedulers: [],
       run_immediately: config.run_immediately
     }}
  end

  @impl true
  def handle_info(:schedule_jobs, state) do
    if state.run_immediately do
      Logger.info("Running all clients immediately (RUN_IMMEDIATELY=1)")
      run_all_immediately(state.config.realdata_clients)
      # After running immediately, we don't schedule recurring jobs
      {:noreply, state}
    else
      Logger.info("Scheduling recurring jobs for all clients")
      schedulers = schedule_all_clients(state.config.realdata_clients)
      {:noreply, %{state | schedulers: schedulers}}
    end
  end

  @impl true
  def handle_info({:run_job, client_config}, state) do
    # This message is sent by Process.send_after for scheduled jobs
    Logger.info("Running scheduled job for client: #{client_config.name}")

    # Spawn the job asynchronously so we don't block the scheduler
    Task.Supervisor.start_child(Financex.TaskSupervisor, fn ->
      Worker.run_job(client_config)
    end)

    # Reschedule for next day (24 hours)
    schedule_next_run(client_config, :timer.hours(24))

    {:noreply, state}
  end

  ## Private Functions

  # Runs all clients immediately without scheduling
  @spec run_all_immediately([RealDataClientConfig.t()]) :: :ok
  defp run_all_immediately(clients) do
    Enum.each(clients, fn client ->
      Logger.info("Starting immediate job for client: #{client.name}")

      # Run each client in a supervised task
      Task.Supervisor.start_child(Financex.TaskSupervisor, fn ->
        case Worker.run_job(client) do
          :ok ->
            Logger.info("Successfully completed immediate job for client: #{client.name}")

          {:error, reason} ->
            Logger.error("Failed immediate job for client: #{client.name}",
              error: inspect(reason)
            )
        end
      end)
    end)

    :ok
  end

  # Schedules all clients according to the staggered schedule
  @spec schedule_all_clients([RealDataClientConfig.t()]) :: [reference()]
  defp schedule_all_clients(clients) do
    clients
    |> Enum.with_index()
    |> Enum.map(fn {client, index} ->
      {hour, minute} = calculate_schedule(index)
      schedule_client(client, hour, minute)
    end)
  end

  # Calculates the hour and minute for a client based on its index
  @spec calculate_schedule(non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  defp calculate_schedule(index) do
    # Calculate minute within the hour (wraps at 60)
    minute = rem(@client_run_delay_minutes * index, @one_hour_minutes)

    # Calculate hour of day (wraps at 24)
    hour_offset = div(index, div(@one_hour_minutes, @client_run_delay_minutes))
    hour = rem(@first_job_start_hour + hour_offset, @one_day_hours)

    {hour, minute}
  end

  # Schedules a single client to run at the specified time each day
  @spec schedule_client(RealDataClientConfig.t(), non_neg_integer(), non_neg_integer()) ::
          reference()
  defp schedule_client(client, hour, minute) do
    cron_schedule = "#{minute} #{hour} * * *"

    Logger.info("Scheduling client: #{client.name}",
      schedule: cron_schedule,
      time: "#{String.pad_leading("#{hour}", 2, "0")}:#{String.pad_leading("#{minute}", 2, "0")}"
    )

    # Calculate milliseconds until next scheduled time
    delay_ms = calculate_initial_delay(hour, minute)

    # Schedule the first run
    schedule_next_run(client, delay_ms)
  end

  # Schedules the next run for a client
  @spec schedule_next_run(RealDataClientConfig.t(), non_neg_integer()) :: reference()
  defp schedule_next_run(client, delay_ms) do
    Process.send_after(self(), {:run_job, client}, delay_ms)
  end

  # Calculates milliseconds until the next occurrence of hour:minute today or tomorrow
  @spec calculate_initial_delay(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp calculate_initial_delay(target_hour, target_minute) do
    now = DateTime.utc_now()
    today = DateTime.to_date(now)

    # Try today first
    target_time =
      DateTime.new!(
        today,
        Time.new!(target_hour, target_minute, 0),
        "Etc/UTC"
      )

    if DateTime.compare(target_time, now) == :gt do
      # Target time is still in the future today
      DateTime.diff(target_time, now, :millisecond)
    else
      # Target time has passed today, schedule for tomorrow
      tomorrow = Date.add(today, 1)

      target_time =
        DateTime.new!(
          tomorrow,
          Time.new!(target_hour, target_minute, 0),
          "Etc/UTC"
        )

      DateTime.diff(target_time, now, :millisecond)
    end
  end
end
