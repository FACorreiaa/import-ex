defmodule Financex.Config do
  @moduledoc """
  Configuration structures for the Financex application.

  This module defines the configuration schemas for:
  - AppConfig: Top-level application configuration
  - RealDataClientConfig: Individual RealData client configurations
  - FTPConfig: FTP server configuration for clients

  ## Structure

  The configuration is loaded from a YAML file (config.yml) with the following structure:

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

  Sensitive data (passwords, API keys) are loaded from environment variables:

  For a client named "krenauer":
  - `RD_KRENAUER_PASSWORD` - RealData login password
  - `RD_KRENAUER_DATA_API_KEY` - Domonda API key
  - `RD_KRENAUER_URL` - FTP URL (optional, if FTP is configured)
  - `RD_KRENAUER_USERNAME` - FTP username (optional, if FTP is configured)
  - `RD_KRENAUER_PASSWORD` - FTP password (optional, if FTP is configured)

  For a client named "kager-knapp", the env vars would be:
  - `RD_KAGER_KNAPP_PASSWORD`
  - `RD_KAGER_KNAPP_DATA_API_KEY`
  - etc.

  Global environment variable:
  - `RUN_IMMEDIATELY` - Set to "1" to run immediately on startup
  """

  require Logger

  @type t :: %__MODULE__{
          run_immediately: boolean(),
          realdata_clients: [RealDataClientConfig.t()]
        }

  defstruct run_immediately: false,
            realdata_clients: []

  defmodule FTPConfig do
    @moduledoc """
    FTP server configuration for a RealData client.

    ## Fields
    - `url` - FTP server URL
    - `username` - FTP username
    - `password` - FTP password (loaded from environment variable)
    """

    @type t :: %__MODULE__{
            url: String.t(),
            username: String.t(),
            password: String.t() | nil
          }

    defstruct [:url, :username, :password]
  end

  defmodule RealDataClientConfig do
    @moduledoc """
    Configuration for a single RealData client.

    This struct contains all the necessary information to authenticate with
    and fetch data from a RealData instance, as well as optional FTP configuration
    for file uploads.

    ## Fields
    - `name` - Client identifier (e.g., "krenauer", "kager-knapp")
    - `base_url` - Base URL for the RealData API
    - `username` - RealData login username
    - `submit_value` - Form submit value for authentication
    - `location_value` - Location value for authentication redirect
    - `client_company_id` - UUID identifying the client company
    - `non_object_specific_account_nos` - Whether account numbers are object-specific
    - `object_endpoint_id` - Endpoint ID for object data
    - `gl_account_endpoint_id` - Endpoint ID for GL account data
    - `partner_endpoint_id` - Endpoint ID for partner data
    - `ftp_config` - Optional FTP configuration
    - `password` - RealData login password (loaded from environment variable)
    - `domonda_api_key` - Domonda API key (loaded from environment variable)
    """

    alias Financex.Config.FTPConfig

    @type t :: %__MODULE__{
            name: String.t(),
            base_url: String.t(),
            username: String.t(),
            submit_value: String.t(),
            location_value: String.t(),
            client_company_id: String.t(),
            non_object_specific_account_nos: boolean(),
            object_endpoint_id: integer(),
            gl_account_endpoint_id: integer(),
            partner_endpoint_id: integer(),
            ftp_config: FTPConfig.t() | nil,
            password: String.t() | nil,
            domonda_api_key: String.t() | nil
          }

    defstruct [
      :name,
      :base_url,
      :username,
      :submit_value,
      :location_value,
      :client_company_id,
      :non_object_specific_account_nos,
      :object_endpoint_id,
      :gl_account_endpoint_id,
      :partner_endpoint_id,
      :ftp_config,
      :password,
      :domonda_api_key
    ]

    @doc """
    Validates that all required fields are present in the client configuration.

    Returns `:ok` if valid, or `{:error, reason}` if invalid.
    """
    @spec validate(t()) :: :ok | {:error, String.t()}
    def validate(%__MODULE__{} = config) do
      required_fields = [
        :name,
        :base_url,
        :username,
        :submit_value,
        :location_value
      ]

      missing =
        Enum.filter(required_fields, fn field ->
          value = Map.get(config, field)
          is_nil(value) or value == ""
        end)

      if missing == [] do
        :ok
      else
        {:error,
         "RealDataClientConfig for '#{config.name}' is missing required fields: #{Enum.join(missing, ", ")}"}
      end
    end
  end

  @doc """
  Parses a raw YAML configuration map into an AppConfig struct.

  This function:
  1. Converts string keys to atoms with proper snake_case naming
  2. Builds RealDataClientConfig structs from the client list
  3. Handles optional FTP configurations

  ## Parameters
  - `yaml_map` - Raw map from YAML parsing

  ## Returns
  - `{:ok, %Financex.Config{}}` on success
  - `{:error, reason}` on failure
  """
  @spec from_yaml(map()) :: {:ok, t()} | {:error, String.t()}
  def from_yaml(yaml_map) when is_map(yaml_map) do
    try do
      clients =
        yaml_map
        |> Map.get("realdata_clients", [])
        |> Enum.map(&parse_client/1)

      config = %__MODULE__{
        run_immediately: Map.get(yaml_map, "run_immediately", false),
        realdata_clients: clients
      }

      {:ok, config}
    rescue
      e -> {:error, "Failed to parse YAML config: #{inspect(e)}"}
    end
  end

  # Parses a single client configuration from YAML map
  defp parse_client(client_map) when is_map(client_map) do
    ftp_config =
      case Map.get(client_map, "ftp") do
        nil ->
          nil

        ftp_map when is_map(ftp_map) ->
          %FTPConfig{
            url: Map.get(ftp_map, "url"),
            username: Map.get(ftp_map, "username"),
            password: nil
          }
      end

    %RealDataClientConfig{
      name: Map.get(client_map, "name"),
      base_url: Map.get(client_map, "base_url"),
      username: Map.get(client_map, "username"),
      submit_value: Map.get(client_map, "submit_value"),
      location_value: Map.get(client_map, "location_value"),
      client_company_id: Map.get(client_map, "client_company_id"),
      non_object_specific_account_nos:
        Map.get(client_map, "nonObjectSpecificAccountNos", false),
      object_endpoint_id: Map.get(client_map, "object_endpoint_id"),
      gl_account_endpoint_id: Map.get(client_map, "glAccount_endpoint_id"),
      partner_endpoint_id: Map.get(client_map, "partner_endpoint_id"),
      ftp_config: ftp_config,
      password: nil,
      domonda_api_key: nil
    }
  end

  @doc """
  Injects environment variables into the client configurations.

  For each client, this loads:
  - Password from `RD_{CLIENT_NAME}_PASSWORD`
  - API key from `RD_{CLIENT_NAME}_DATA_API_KEY`
  - FTP credentials from `RD_{CLIENT_NAME}_URL`, `RD_{CLIENT_NAME}_USERNAME`, `RD_{CLIENT_NAME}_PASSWORD` (if FTP is configured)

  Client names are transformed to uppercase and hyphens are replaced with underscores.
  For example, "kager-knapp" becomes "KAGER_KNAPP".

  ## Parameters
  - `config` - AppConfig struct with client configurations

  ## Returns
  - `{:ok, %Financex.Config{}}` with secrets injected
  - `{:error, reason}` if required environment variables are missing or company IDs are duplicated
  """
  @spec inject_secrets(t()) :: {:ok, t()} | {:error, String.t()}
  def inject_secrets(%__MODULE__{} = config) do
    # Check for duplicate company IDs first
    company_id_map =
      Enum.reduce(config.realdata_clients, %{}, fn client, acc ->
        Map.put(acc, client.client_company_id, client.name)
      end)

    if map_size(company_id_map) != length(config.realdata_clients) do
      duplicates =
        config.realdata_clients
        |> Enum.group_by(& &1.client_company_id)
        |> Enum.filter(fn {_id, clients} -> length(clients) > 1 end)
        |> Enum.map(fn {id, clients} ->
          names = Enum.map_join(clients, ", ", & &1.name)
          "#{id} is used by: #{names}"
        end)
        |> Enum.join("; ")

      {:error, "Duplicate ClientCompanyID found: #{duplicates}"}
    else
      # Inject secrets for each client
      case inject_client_secrets(config.realdata_clients, []) do
        {:ok, updated_clients} ->
          # Check RUN_IMMEDIATELY env var
          run_immediately = System.get_env("RUN_IMMEDIATELY") == "1"

          {:ok, %{config | realdata_clients: updated_clients, run_immediately: run_immediately}}

        {:error, _} = error ->
          error
      end
    end
  end

  # Recursively inject secrets for each client
  defp inject_client_secrets([], acc), do: {:ok, Enum.reverse(acc)}

  defp inject_client_secrets([client | rest], acc) do
    # Transform client name to env var format
    client_name_upper =
      client.name
      |> String.upcase()
      |> String.replace("-", "_")

    Logger.debug("Loading secrets for client: #{client.name} (#{client_name_upper})",
      company_id: client.client_company_id
    )

    password_var = "RD_#{client_name_upper}_PASSWORD"
    api_key_var = "RD_#{client_name_upper}_DATA_API_KEY"

    password = System.get_env(password_var)
    api_key = System.get_env(api_key_var)

    cond do
      is_nil(password) or password == "" ->
        {:error, "Missing required environment variable for client '#{client.name}': #{password_var}"}

      is_nil(api_key) or api_key == "" ->
        {:error, "Missing required environment variable for client '#{client.name}': #{api_key_var}"}

      true ->
        # Inject FTP secrets if FTP is configured
        updated_ftp =
          if client.ftp_config do
            ftp_url_var = "RD_#{client_name_upper}_URL"
            ftp_username_var = "RD_#{client_name_upper}_USERNAME"
            ftp_password_var = "RD_#{client_name_upper}_PASSWORD"

            %FTPConfig{
              url: System.get_env(ftp_url_var) || client.ftp_config.url,
              username: System.get_env(ftp_username_var) || client.ftp_config.username,
              password: System.get_env(ftp_password_var)
            }
          else
            nil
          end

        updated_client = %{
          client
          | password: password,
            domonda_api_key: api_key,
            ftp_config: updated_ftp
        }

        Logger.debug("Successfully injected secrets for client: #{client.name}")
        inject_client_secrets(rest, [updated_client | acc])
    end
  end
end
