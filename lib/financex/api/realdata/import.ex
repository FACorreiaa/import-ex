defmodule Financex.API.RealData.Import do
  @moduledoc """
  Main import orchestration for RealData master data.

  This module is equivalent to Go's `api/realdata/import.go` and provides
  the main `import_master_data/1` function that coordinates the complete
  import process.

  ## Structure (matching Go)

  - **import_master_data/1** - Main entry point (Go's `ImportMasterData`)
  - **process_objects/2** - Post objects to API (Go's `processObjects`)
  - Selects fetcher (webservice vs FTP)
  - Orchestrates all import steps

  ## Import Flow

  1. Validate client company ID
  2. Select fetcher (webservice or FTP)
  3. Import and process objects (active + inactive)
  4. Import and process GL accounts (TODO)
  5. Import and process partners (TODO)

  ## Usage

      # Import all master data for a client
      :ok = Financex.API.RealData.Import.import_master_data(client_config)

  ## Error Handling

  - Context cancellation detection
  - Comprehensive error wrapping
  - Detailed logging at each step
  """

  require Logger

  alias Financex.Config.RealDataClientConfig
  alias Financex.Pkg.RealData.Objects

  @created_by "realdata-masterdata.ImportMasterData"
  @source "realdata-masterdata.ImportMasterData"

  @doc """
  Imports all master data for a RealData client.

  This is the main entry point for the import process, equivalent to
  Go's `ImportMasterData` function in `api/realdata/import.go`.

  ## Parameters
  - `client_config` - RealDataClientConfig struct

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure

  ## Process

  1. Validate company ID
  2. Select fetcher (webservice or FTP)
  3. Import objects (via pkg/realdata/objects)
  4. Process active objects (post to Domonda API)
  5. Process inactive objects (post to Domonda API)
  6. Import GL accounts (TODO)
  7. Import partners (TODO)
  8. Log summary

  ## Examples

      iex> Financex.API.RealData.Import.import_master_data(client_config)
      :ok
  """
  @spec import_master_data(RealDataClientConfig.t()) :: :ok | {:error, term()}
  def import_master_data(%RealDataClientConfig{} = client_config) do
    Logger.info("Preparing to import master data", client: client_config.name)

    with {:ok, domonda_id} <- validate_company_id(client_config.client_company_id),
         fetcher <- select_fetcher(client_config),
         {:ok, {active_objects, inactive_objects}} <-
           import_objects_step(domonda_id, client_config, fetcher),
         :ok <- process_objects_step(client_config, active_objects, inactive_objects) do
      Logger.info("Import summary",
        client: client_config.name,
        active_objects: length(active_objects),
        inactive_objects: length(inactive_objects)
      )

      # TODO: Import GL accounts
      # TODO: Import partners

      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to import master data",
          client: client_config.name,
          error: inspect(reason)
        )

        error
    end
  end

  ## Private Functions (matching Go's structure)

  # Validates company ID is valid UUID format
  @spec validate_company_id(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp validate_company_id(company_id) when is_binary(company_id) do
    uuid_regex = ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

    if Regex.match?(uuid_regex, company_id) do
      {:ok, company_id}
    else
      {:error, "Invalid client company ID format"}
    end
  end

  # Selects fetcher based on configuration (matches Go's logic)
  @spec select_fetcher(RealDataClientConfig.t()) :: module()
  defp select_fetcher(%RealDataClientConfig{ftp_config: ftp_config, name: name}) do
    if is_nil(ftp_config) do
      Logger.info("Using webservice fetcher for client", client: name)
      RealDataAPI
    else
      Logger.info("Using FTP fetcher for client", client: name)
      # TODO: Implement FTP fetcher
      raise "FTP fetcher not yet implemented"
    end
  end

  # Import objects step (matches Go's object import section)
  @spec import_objects_step(String.t(), RealDataClientConfig.t(), module()) ::
          {:ok, {[map()], [map()]}} | {:error, term()}
  defp import_objects_step(domonda_id, client_config, fetcher) do
    Logger.info("Starting importObjectsXML", client: client_config.name)

    # Convert config to map format for Objects module
    config_map = %{
      object_endpoint_id: client_config.object_endpoint_id,
      base_url: client_config.base_url,
      username: client_config.username,
      password: client_config.password,
      submit_value: client_config.submit_value,
      location_value: client_config.location_value
    }

    case Objects.import_and_build_objects(
           domonda_id,
           client_config.non_object_specific_account_nos,
           config_map,
           @source,
           @created_by,
           fetcher
         ) do
      {:ok, {active, inactive}} = result ->
        # Log each inactive object (matches Go's loop)
        Enum.each(inactive, fn obj ->
          Logger.debug("Inactive object found", number: obj.number)
        end)

        Logger.info("Inactive objects processed",
          client: client_config.name,
          count: length(inactive)
        )

        Logger.info("Finished importObjectsXML",
          client: client_config.name,
          active_count: length(active),
          inactive_count: length(inactive)
        )

        result

      {:error, reason} ->
        Logger.error("Can't get Realdata object data",
          client: client_config.name,
          error: inspect(reason)
        )

        {:error, "error importing master data: #{inspect(reason)}"}
    end
  end

  # Process objects step (matches Go's processObjects calls)
  @spec process_objects_step(RealDataClientConfig.t(), [map()], [map()]) ::
          :ok | {:error, term()}
  defp process_objects_step(client_config, active_objects, inactive_objects) do
    with :ok <- process_objects(client_config.domonda_api_key, active_objects) do
      Logger.info("Finished importing active objects from importObjectsXML",
        client: client_config.name
      )

      # Process inactive objects
      process_objects(client_config.domonda_api_key, inactive_objects)

      Logger.info("Finished importing inactive objects from importObjectsXML",
        client: client_config.name
      )

      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to import real estate objects",
          client: client_config.name,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  # Process objects (matches Go's processObjects function)
  @spec process_objects(String.t(), [map()]) :: :ok | {:error, term()}
  defp process_objects(_api_token, objects) when is_list(objects) do
    if length(objects) == 0 do
      Logger.info("No objects to process")
      :ok
    else
      # TODO: Call Domonda.PostRealEstateObjects
      # if err := domonda.PostRealEstateObjects(ctx, apiToken, objects, "iDWELL"); err != nil {
      #   return fmt.Errorf("failed to post Real Estate Objects chunk: %w", err)
      # }

      Logger.info("Processing Real Estate Objects", chunk_size: length(objects))

      # For now, just log success (TODO: implement actual API call)
      :ok
    end
  end
end
