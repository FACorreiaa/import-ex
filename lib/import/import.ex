defmodule Financex.Import do
  @moduledoc """
  Entry point for the Financex data import application.

  This module orchestrates the loading of configuration from YAML files and
  initializing the import process for RealData clients.

  ## Configuration Loading Strategy

  The module attempts to load configuration in the following order:

  1. **External YAML file** from one of these locations:
     - `./config.yml`
     - `./config/config.yml`
     - `/app/config.yml`
     - `/app/config/config.yml`
     - `/app/config/realdata/config.yml`

  2. **Embedded YAML file** (if external file not found):
     - Falls back to `priv/config.yml` embedded in the application

  ## Configuration Structure

  The YAML file should have this structure:

      run_immediately: true
      realdata_clients:
        - name: "krenauer"
          base_url: "https://online.krenauer.at/acureal/webreal.acu"
          username: "idwell"
          submit_value: "register"
          location_value: "webreal.acu?id=01"
          client_company_id: "ed8d1964-4cc6-4e8c-a112-4cf3777d7ef0"
          nonObjectSpecificAccountNos: false
          object_endpoint_id: 80
          glAccount_endpoint_id: 83
          partner_endpoint_id: 82
          ftp:
            url: "ftp.example.com"
            username: "ftpuser"

  ## Environment Variables

  Sensitive credentials must be provided via environment variables:

  For each client, set:
  - `RD_{CLIENT_NAME}_PASSWORD` - RealData login password
  - `RD_{CLIENT_NAME}_DATA_API_KEY` - Domonda API key
  - `RD_{CLIENT_NAME}_URL` - FTP URL (if FTP configured)
  - `RD_{CLIENT_NAME}_USERNAME` - FTP username (if FTP configured)
  - `RD_{CLIENT_NAME}_PASSWORD` - FTP password (if FTP configured)

  Global settings:
  - `RUN_IMMEDIATELY=1` - Run import immediately on startup

  ## Usage

      # Initialize configuration
      {:ok, config} = Financex.Import.init_config()

      # Start import process
      Financex.Import.run(config)

  ## Example

      iex> {:ok, config} = Financex.Import.init_config()
      {:ok, %Financex.Config{run_immediately: true, realdata_clients: [...]}}

      iex> Financex.Import.run(config)
      :ok
  """

  require Logger

  alias Financex.Config
  alias Financex.Config.RealDataClientConfig

  @config_paths [
    ".",
    "config",
    "/app",
    "/app/config",
    "/app/config/realdata"
  ]

  @config_name "config.yml"
  @embedded_config_path "priv/config.yml"

  @doc """
  Initializes the application configuration.

  This function:
  1. Searches for a YAML config file in predefined paths
  2. Falls back to embedded config if no external file is found
  3. Parses the YAML into an AppConfig struct
  4. Validates all client configurations
  5. Injects secrets from environment variables
  6. Checks for duplicate company IDs

  ## Returns
  - `{:ok, %Financex.Config{}}` - Successfully loaded and validated configuration
  - `{:error, reason}` - Configuration loading or validation failed

  ## Examples

      iex> Financex.Import.init_config()
      {:ok, %Financex.Config{run_immediately: true, realdata_clients: [...]}}
  """
  @spec init_config() :: {:ok, Config.t()} | {:error, String.t()}
  def init_config do
    Logger.info("Initializing configuration...")

    with {:ok, yaml_content} <- load_config_file(),
         {:ok, yaml_map} <- parse_yaml(yaml_content),
         {:ok, config} <- Config.from_yaml(yaml_map),
         :ok <- validate_clients(config),
         {:ok, config_with_secrets} <- Config.inject_secrets(config) do
      Logger.info("Configuration loaded successfully",
        client_count: length(config_with_secrets.realdata_clients),
        run_immediately: config_with_secrets.run_immediately
      )

      {:ok, config_with_secrets}
    else
      {:error, reason} = error ->
        Logger.error("Failed to initialize configuration: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Runs the import process for all configured RealData clients.

  This function iterates through each client configuration and fetches data
  from the configured endpoints.

  ## Parameters
  - `config` - Validated AppConfig struct with all secrets injected

  ## Returns
  - `:ok` on successful completion
  - `{:error, reason}` if import fails

  ## Examples

      iex> {:ok, config} = Financex.Import.init_config()
      iex> Financex.Import.run(config)
      :ok
  """
  @spec run(Config.t()) :: :ok | {:error, term()}
  def run(%Config{} = config) do
    Logger.info("Starting import process for #{length(config.realdata_clients)} client(s)...")

    results =
      Enum.map(config.realdata_clients, fn client ->
        process_client(client)
      end)

    failed = Enum.filter(results, fn result -> match?({:error, _}, result) end)

    if failed == [] do
      Logger.info("Import process completed successfully for all clients")
      :ok
    else
      Logger.error("Import process failed for #{length(failed)} client(s)")
      {:error, "Some clients failed to import"}
    end
  end

  # Private functions

  # Attempts to load config file from predefined paths or embedded config
  @spec load_config_file() :: {:ok, String.t()} | {:error, String.t()}
  defp load_config_file do
    # Try external paths first
    case try_external_paths(@config_paths, @config_name) do
      {:ok, content, path} ->
        Logger.info("Successfully loaded external config file", path: path)
        {:ok, content}

      :not_found ->
        Logger.info("No external config file found, falling back to embedded config")
        load_embedded_config()
    end
  end

  # Tries to load config from multiple external paths
  @spec try_external_paths([String.t()], String.t()) ::
          {:ok, String.t(), String.t()} | :not_found
  defp try_external_paths([], _config_name), do: :not_found

  defp try_external_paths([path | rest], config_name) do
    full_path = Path.join(path, config_name)

    case File.read(full_path) do
      {:ok, content} ->
        {:ok, content, full_path}

      {:error, :enoent} ->
        try_external_paths(rest, config_name)

      {:error, reason} ->
        Logger.warning("Failed to read config at #{full_path}: #{inspect(reason)}")
        try_external_paths(rest, config_name)
    end
  end

  # Loads the embedded config file from priv directory
  @spec load_embedded_config() :: {:ok, String.t()} | {:error, String.t()}
  defp load_embedded_config do
    app_dir = Application.app_dir(:financex)
    embedded_path = Path.join(app_dir, @embedded_config_path)

    case File.read(embedded_path) do
      {:ok, content} ->
        Logger.info("Successfully loaded embedded config", path: embedded_path)
        {:ok, content}

      {:error, reason} ->
        Logger.error("Failed to read embedded config at #{embedded_path}: #{inspect(reason)}")

        {:error,
         "External config not found AND failed to read embedded config: #{inspect(reason)}"}
    end
  end

  # Parses YAML content into a map
  @spec parse_yaml(String.t()) :: {:ok, map()} | {:error, String.t()}
  defp parse_yaml(yaml_content) do
    case YamlElixir.read_from_string(yaml_content) do
      {:ok, yaml_map} ->
        {:ok, yaml_map}

      {:error, reason} ->
        Logger.error("Failed to parse YAML: #{inspect(reason)}")
        {:error, "Failed to parse YAML: #{inspect(reason)}"}
    end
  end

  # Validates all client configurations
  @spec validate_clients(Config.t()) :: :ok | {:error, String.t()}
  defp validate_clients(%Config{realdata_clients: clients}) do
    Logger.debug("Validating #{length(clients)} client configuration(s)...")

    errors =
      clients
      |> Enum.map(&RealDataClientConfig.validate/1)
      |> Enum.filter(fn result -> match?({:error, _}, result) end)

    if errors == [] do
      Logger.debug("All client configurations are valid")
      :ok
    else
      error_messages = Enum.map_join(errors, "; ", fn {:error, msg} -> msg end)
      Logger.error("Client validation failed: #{error_messages}")
      {:error, error_messages}
    end
  end

  # Processes a single RealData client
  @spec process_client(RealDataClientConfig.t()) :: :ok | {:error, term()}
  defp process_client(%RealDataClientConfig{} = client) do
    Logger.info("Processing client: #{client.name}",
      company_id: client.client_company_id,
      base_url: client.base_url
    )

    # Convert config to map format expected by RealDataAPI
    config_map = %{
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

    # Fetch data from each endpoint
    with {:ok, object_data} <- fetch_endpoint(config_map, client.object_endpoint_id, "objects"),
         {:ok, gl_data} <- fetch_endpoint(config_map, client.gl_account_endpoint_id, "GL accounts"),
         {:ok, partner_data} <- fetch_endpoint(config_map, client.partner_endpoint_id, "partners") do
      Logger.info("Successfully fetched all data for client: #{client.name}",
        object_bytes: byte_size(object_data),
        gl_bytes: byte_size(gl_data),
        partner_bytes: byte_size(partner_data)
      )

      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to process client: #{client.name}", error: inspect(reason))
        error
    end
  end

  # Fetches data from a specific endpoint
  @spec fetch_endpoint(map(), integer(), String.t()) :: {:ok, binary()} | {:error, term()}
  defp fetch_endpoint(config, endpoint_id, endpoint_name) do
    Logger.debug("Fetching #{endpoint_name} data",
      client: config["name"],
      endpoint_id: endpoint_id
    )

    case RealDataAPI.fetch(config, endpoint_id) do
      {:ok, data} ->
        Logger.debug("Successfully fetched #{endpoint_name} data",
          client: config["name"],
          bytes: byte_size(data)
        )

        {:ok, data}

      {:error, reason} = error ->
        Logger.error("Failed to fetch #{endpoint_name} data",
          client: config["name"],
          endpoint_id: endpoint_id,
          error: inspect(reason)
        )

        error
    end
  end
end
