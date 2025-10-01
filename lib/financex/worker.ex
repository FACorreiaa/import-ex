defmodule Financex.Worker do
  @moduledoc """
  Worker module for executing RealData import jobs with retry logic.

  This module handles the execution of individual import jobs for RealData clients.
  It implements:
  - Timeout management (30 minutes per job)
  - Retry logic (up to 10 attempts)
  - Delay between retries (15 minutes)
  - Comprehensive logging of all attempts

  ## Job Execution Flow

  1. Start job with timeout
  2. Call RealDataAPI to fetch data
  3. On success: log and return
  4. On failure: retry up to max attempts
  5. Wait 15 minutes between retries
  6. Log final outcome

  ## Timeout Handling

  Each job has a 30-minute timeout. If the job doesn't complete within this time,
  it's considered failed and will be retried.

  ## Retry Strategy

  - Maximum retries: 10
  - Retry delay: 15 minutes
  - Exponential backoff: Not implemented (constant 15-minute delay)
  - Cancellation: Jobs respect process cancellation signals

  ## Usage

      # Run a single job
      :ok = Financex.Worker.run_job(client_config)

      # Run a job with custom retry settings
      :ok = Financex.Worker.run_job(client_config, max_retries: 5, retry_delay: 5 * 60 * 1000)
  """

  require Logger

  alias Financex.Config.RealDataClientConfig

  # Constants matching the Go implementation
  @max_retries 10
  @timeout_duration :timer.minutes(30)
  @retry_delay :timer.minutes(15)

  @doc """
  Runs an import job for a single RealData client with retry logic.

  This function:
  1. Fetches data from all three endpoints (objects, GL accounts, partners)
  2. Retries on failure up to `max_retries` times
  3. Waits `retry_delay` milliseconds between retries
  4. Times out after `timeout` milliseconds

  ## Parameters
  - `client_config` - RealDataClientConfig struct with client settings
  - `opts` - Optional keyword list with:
    - `:max_retries` - Maximum retry attempts (default: 10)
    - `:retry_delay` - Milliseconds to wait between retries (default: 15 minutes)
    - `:timeout` - Milliseconds before timing out (default: 30 minutes)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on final failure after all retries

  ## Examples

      iex> Financex.Worker.run_job(config)
      :ok

      iex> Financex.Worker.run_job(config, max_retries: 5)
      :ok
  """
  @spec run_job(RealDataClientConfig.t(), keyword()) :: :ok | {:error, term()}
  def run_job(%RealDataClientConfig{} = client_config, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, @max_retries)
    retry_delay = Keyword.get(opts, :retry_delay, @retry_delay)
    timeout = Keyword.get(opts, :timeout, @timeout_duration)

    Logger.info("Starting import job for client: #{client_config.name}")

    run_with_retries(client_config, 1, max_retries, retry_delay, timeout)
  end

  ## Private Functions

  # Recursively attempts the job with retries
  @spec run_with_retries(
          RealDataClientConfig.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok | {:error, term()}
  defp run_with_retries(client_config, attempt, max_retries, retry_delay, timeout)
       when attempt <= max_retries do
    start_time = System.monotonic_time(:millisecond)

    Logger.info("Import attempt #{attempt}/#{max_retries} for client: #{client_config.name}")

    case execute_job_with_timeout(client_config, timeout) do
      :ok ->
        duration = System.monotonic_time(:millisecond) - start_time

        Logger.info("Import job completed successfully for client: #{client_config.name}",
          duration_ms: duration,
          duration_seconds: div(duration, 1000)
        )

        :ok

      {:error, reason} = error ->
        Logger.error("Import job failed for client: #{client_config.name}",
          attempt: "#{attempt}/#{max_retries}",
          error: inspect(reason)
        )

        if attempt < max_retries do
          Logger.info("Retrying in #{div(retry_delay, 60_000)} minutes...",
            client: client_config.name
          )

          # Sleep before retrying (respects process messages for graceful shutdown)
          receive do
            :shutdown -> {:error, :shutdown}
          after
            retry_delay ->
              run_with_retries(client_config, attempt + 1, max_retries, retry_delay, timeout)
          end
        else
          Logger.warning("Import job failed after all retries for client: #{client_config.name}",
            total_attempts: max_retries
          )

          error
        end
    end
  end

  # Executes the job with a timeout wrapper
  @spec execute_job_with_timeout(RealDataClientConfig.t(), non_neg_integer()) ::
          :ok | {:error, term()}
  defp execute_job_with_timeout(client_config, timeout) do
    task =
      Task.async(fn ->
        execute_job(client_config)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} ->
        result

      nil ->
        Logger.error("Job timed out after #{div(timeout, 60_000)} minutes",
          client: client_config.name
        )

        {:error, :timeout}
    end
  end

  # Executes the actual import job by fetching data from all endpoints
  @spec execute_job(RealDataClientConfig.t()) :: :ok | {:error, term()}
  defp execute_job(%RealDataClientConfig{} = client) do
    Logger.debug("Executing import for client: #{client.name}",
      company_id: client.client_company_id,
      base_url: client.base_url
    )

    # Convert config to map format expected by RealDataAPI
    config_map = client_config_to_map(client)

    # Fetch data from all three endpoints
    with {:ok, object_data} <-
           fetch_endpoint(config_map, client.object_endpoint_id, "objects", client.name),
         {:ok, gl_data} <-
           fetch_endpoint(config_map, client.gl_account_endpoint_id, "GL accounts", client.name),
         {:ok, partner_data} <-
           fetch_endpoint(config_map, client.partner_endpoint_id, "partners", client.name) do
      Logger.info("Successfully fetched all endpoint data for client: #{client.name}",
        object_bytes: byte_size(object_data),
        gl_bytes: byte_size(gl_data),
        partner_bytes: byte_size(partner_data),
        total_bytes: byte_size(object_data) + byte_size(gl_data) + byte_size(partner_data)
      )

      # TODO: Process and store the data
      # For now, we just log success
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to execute import for client: #{client.name}",
          error: inspect(reason)
        )

        error
    end
  end

  # Converts RealDataClientConfig struct to map format for RealDataAPI
  @spec client_config_to_map(RealDataClientConfig.t()) :: map()
  defp client_config_to_map(client) do
    %{
      "name" => client.name,
      "base_url" => client.base_url,
      "username" => client.username,
      "password" => client.password,
      "submit_value" => client.submit_value,
      "location_value" => client.location_value,
      "client_company_id" => client.client_company_id,
      "nonObjectSpecificAccountNos" => client.non_object_specific_account_nos,
      "object_endpoint_id" => client.object_endpoint_id,
      "glAccount_endpoint_id" => client.gl_account_endpoint_id,
      "partner_endpoint_id" => client.partner_endpoint_id
    }
  end

  # Fetches data from a specific endpoint with logging
  @spec fetch_endpoint(map(), integer(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  defp fetch_endpoint(config, endpoint_id, endpoint_name, client_name) do
    Logger.debug("Fetching #{endpoint_name} data",
      client: client_name,
      endpoint_id: endpoint_id
    )

    start_time = System.monotonic_time(:millisecond)

    case RealDataAPI.fetch(config, endpoint_id) do
      {:ok, data} ->
        duration = System.monotonic_time(:millisecond) - start_time

        Logger.debug("Successfully fetched #{endpoint_name} data",
          client: client_name,
          endpoint_id: endpoint_id,
          bytes: byte_size(data),
          duration_ms: duration
        )

        {:ok, data}

      {:error, reason} = error ->
        Logger.error("Failed to fetch #{endpoint_name} data",
          client: client_name,
          endpoint_id: endpoint_id,
          error: inspect(reason)
        )

        error
    end
  end
end
