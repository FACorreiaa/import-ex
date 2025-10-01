defmodule Mix.Tasks.Financex.Import do
  @moduledoc """
  Mix task for running RealData imports.

  This task provides a command-line interface for running import jobs
  without starting the full application supervisor tree.

  ## Usage

  Run all configured clients immediately:

      mix financex.import

  Run a specific client by name:

      mix financex.import krenauer

  Run with custom retry settings:

      mix financex.import --max-retries 5 --timeout 600000

  ## Options

  - `--max-retries` - Maximum number of retry attempts (default: 10)
  - `--retry-delay` - Milliseconds to wait between retries (default: 900000 = 15 minutes)
  - `--timeout` - Milliseconds before timing out a job (default: 1800000 = 30 minutes)

  ## Examples

      # Run all clients with default settings
      mix financex.import

      # Run only the "krenauer" client
      mix financex.import krenauer

      # Run with faster retries for testing
      mix financex.import --max-retries 3 --retry-delay 60000 --timeout 300000

      # Run a specific client with custom settings
      mix financex.import kreissl --max-retries 5

  ## Environment Variables

  The task requires the same environment variables as the main application:

  For each client:
  - `RD_{CLIENT_NAME}_PASSWORD` - RealData login password
  - `RD_{CLIENT_NAME}_DATA_API_KEY` - Domonda API key

  Example:
      export RD_KRENAUER_PASSWORD="secret"
      export RD_KRENAUER_DATA_API_KEY="api_key"
      mix financex.import krenauer

  ## Exit Codes

  - 0: Success - all imports completed successfully
  - 1: Error - configuration failed to load or one or more imports failed
  """

  use Mix.Task
  require Logger

  alias Financex.Config.RealDataClientConfig
  alias Financex.Worker

  @shortdoc "Runs RealData import jobs"

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    # Ensure logger is configured
    Logger.configure(level: :info)

    {opts, positional_args, _invalid} =
      OptionParser.parse(args,
        strict: [
          max_retries: :integer,
          retry_delay: :integer,
          timeout: :integer
        ]
      )

    # Load configuration
    case Financex.Import.init_config() do
      {:ok, config} ->
        client_name = List.first(positional_args)
        run_imports(config, client_name, opts)

      {:error, reason} ->
        Mix.Shell.IO.error("Failed to load configuration: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  ## Private Functions

  # Runs imports for all clients or a specific client
  @spec run_imports(Financex.Config.t(), String.t() | nil, keyword()) :: :ok
  defp run_imports(config, nil, opts) do
    # Run all clients
    Mix.Shell.IO.info("Running import for all #{length(config.realdata_clients)} client(s)...")

    results =
      config.realdata_clients
      |> Enum.map(fn client ->
        {client.name, run_single_client(client, opts)}
      end)

    report_results(results)
  end

  defp run_imports(config, client_name, opts) do
    # Run specific client
    case find_client(config.realdata_clients, client_name) do
      nil ->
        Mix.Shell.IO.error("Client '#{client_name}' not found in configuration")

        available = Enum.map_join(config.realdata_clients, ", ", & &1.name)
        Mix.Shell.IO.info("Available clients: #{available}")

        exit({:shutdown, 1})

      client ->
        Mix.Shell.IO.info("Running import for client: #{client_name}")

        case run_single_client(client, opts) do
          :ok ->
            Mix.Shell.IO.info("✓ Import completed successfully for #{client_name}")
            :ok

          {:error, reason} ->
            Mix.Shell.IO.error("✗ Import failed for #{client_name}: #{inspect(reason)}")
            exit({:shutdown, 1})
        end
    end
  end

  # Finds a client by name
  @spec find_client([RealDataClientConfig.t()], String.t()) :: RealDataClientConfig.t() | nil
  defp find_client(clients, name) do
    Enum.find(clients, fn client -> client.name == name end)
  end

  # Runs import for a single client
  @spec run_single_client(RealDataClientConfig.t(), keyword()) :: :ok | {:error, term()}
  defp run_single_client(client, opts) do
    Mix.Shell.IO.info("Starting import for #{client.name}...")
    start_time = System.monotonic_time(:millisecond)

    result = Worker.run_job(client, opts)

    duration_ms = System.monotonic_time(:millisecond) - start_time
    duration_sec = div(duration_ms, 1000)

    case result do
      :ok ->
        Mix.Shell.IO.info("✓ #{client.name} completed in #{duration_sec}s")

      {:error, reason} ->
        Mix.Shell.IO.error("✗ #{client.name} failed after #{duration_sec}s: #{inspect(reason)}")
    end

    result
  end

  # Reports results for multiple clients
  @spec report_results([{String.t(), :ok | {:error, term()}}]) :: :ok
  defp report_results(results) do
    total = length(results)
    successful = Enum.count(results, fn {_, result} -> result == :ok end)
    failed = total - successful

    Mix.Shell.IO.info("\n" <> String.duplicate("=", 50))
    Mix.Shell.IO.info("Import Summary")
    Mix.Shell.IO.info(String.duplicate("=", 50))
    Mix.Shell.IO.info("Total clients: #{total}")
    Mix.Shell.IO.info("Successful:    #{successful}")
    Mix.Shell.IO.info("Failed:        #{failed}")
    Mix.Shell.IO.info(String.duplicate("=", 50))

    if failed > 0 do
      Mix.Shell.IO.error("\nFailed clients:")

      results
      |> Enum.filter(fn {_, result} -> match?({:error, _}, result) end)
      |> Enum.each(fn {name, {:error, reason}} ->
        Mix.Shell.IO.error("  - #{name}: #{inspect(reason)}")
      end)

      exit({:shutdown, 1})
    else
      Mix.Shell.IO.info("\n✓ All imports completed successfully!")
      :ok
    end
  end
end
