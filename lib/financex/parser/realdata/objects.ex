defmodule Financex.Pkg.RealData.Objects do
  @moduledoc """
  Core parsing and building logic for RealData objects.

  This module contains the low-level parsing and transformation logic for
  RealData objects, matching the Go `pkg/realdata/objects.go` structure.

  ## Responsibilities

  - Parse XML data into Object structs
  - Validate and clean object data
  - Build API-ready RealEstateObject structs
  - Separate active and inactive objects

  ## Structure

  This module is equivalent to Go's `pkg/realdata/objects.go` and provides:
  - `ParseObjects/1` - Parse raw XML into Object structs
  - `ParseObjectsXML/3` - Parse with context and validation
  - `ImportAndBuildObjects/6` - Full import pipeline
  - `buildRealEstateObject/4` - Transform to API format

  ## Usage

      # Low-level parsing
      {:ok, {active, inactive}} = Financex.Pkg.RealData.Objects.parse_objects(xml_data)

      # Full import with fetcher
      {:ok, {active_objs, inactive_objs}} =
        Financex.Pkg.RealData.Objects.import_and_build_objects(
          client_company_id,
          non_object_specific_account_nos,
          client_config,
          source,
          created_by,
          fetcher
        )
  """

  require Logger
  import SweetXml

  @active_record "0"

  @type object :: %{
          index: String.t(),
          object_nr: String.t(),
          typ: String.t(),
          record_status: String.t(),
          administration_start: String.t(),
          administration_end: String.t(),
          location: String.t(),
          street: String.t(),
          responsible_person: String.t()
        }

  @type real_estate_object :: %{
          number: String.t(),
          type: :hi | :weg | :sub,
          street_address: String.t(),
          zip_code: String.t(),
          country: String.t(),
          active: boolean()
        }

  @doc """
  Parses raw XML data into Object structs.

  Low-level parsing function that extracts object data from XML and
  performs initial validation and cleaning.

  Equivalent to Go's `ParseObjects` function.

  ## Parameters
  - `xml_data` - Binary XML data from RealData

  ## Returns
  - `{:ok, {active_objects, inactive_objects}}` on success
  - `{:error, reason}` on failure
  """
  @spec parse_objects(binary()) :: {:ok, {[object()], [object()]}} | {:error, term()}
  def parse_objects(xml_data) when is_binary(xml_data) do
    Logger.debug("Parsing objects XML", bytes: byte_size(xml_data))

    try do
      objects =
        xml_data
        |> xpath(
          ~x"//objekt"l,
          index: ~x"./objektkey/text()"s,
          object_nr: ~x"./objektnr/text()"s,
          typ: ~x"./typ/text()"s,
          record_status: ~x"./recstatus/text()"s,
          administration_start: ~x"./verwaltungsueb/text()"s,
          administration_end: ~x"./verwaltungsende/text()"s,
          location: ~x"./objektort/text()"s,
          street: ~x"./objektstrasse/text()"s,
          responsible_person: ~x"./sachb/text()"s
        )

      {active, inactive} = process_and_separate_objects(objects)

      {:ok, {active, inactive}}
    rescue
      e ->
        Logger.error("Failed to parse XML: #{Exception.message(e)}")
        {:error, "failed to parse XML: #{Exception.message(e)}"}
    end
  end

  @doc """
  Parses objects XML with client context and validation.

  This function wraps `parse_objects/1` with additional logging and validation.
  Equivalent to Go's `ParseObjectsXML` function.

  ## Parameters
  - `client_company_id` - UUID of the client company
  - `xml_data` - Binary XML data
  - `_non_object_specific_account_nos` - Account number handling flag (currently unused)

  ## Returns
  - `{:ok, {active_objects, inactive_objects}}` on success
  - `{:error, reason}` on failure
  """
  @spec parse_objects_xml(String.t(), binary(), boolean()) ::
          {:ok, {[object()], [object()]}} | {:error, term()}
  def parse_objects_xml(client_company_id, xml_data, _non_object_specific_account_nos)
      when is_binary(xml_data) do
    if byte_size(xml_data) == 0 do
      {:error, "object XML data is empty for clientCompanyID: #{client_company_id}"}
    else
      Logger.info("Importing masterdata from XML files",
        client_company_id: client_company_id
      )

      parse_objects(xml_data)
    end
  end

  @doc """
  Imports objects from fetcher and builds API-ready structures.

  This is the main entry point for object import. It orchestrates fetching,
  parsing, and building API-ready real estate objects.

  Equivalent to Go's `ImportAndBuildObjects` function.

  ## Parameters
  - `client_company_id` - UUID of the client company
  - `_non_object_specific_account_nos` - Account number handling flag
  - `client_config` - Client configuration map
  - `source` - Source identifier for tracking
  - `created_by` - User/system that initiated import
  - `fetcher` - Module implementing fetch/2 behavior

  ## Returns
  - `{:ok, {active_objects, inactive_objects}}` - API-ready objects
  - `{:error, reason}` on failure
  """
  @spec import_and_build_objects(
          String.t(),
          boolean(),
          map(),
          String.t(),
          String.t(),
          module()
        ) :: {:ok, {[real_estate_object()], [real_estate_object()]}} | {:error, term()}
  def import_and_build_objects(
        client_company_id,
        non_object_specific_account_nos,
        client_config,
        source,
        created_by,
        fetcher
      ) do
    Logger.info("Importing objects",
      client_company_id: client_company_id,
      source: source,
      created_by: created_by
    )

    with {:ok, raw_active, raw_inactive} <-
           import_objects_xml(
             client_company_id,
             non_object_specific_account_nos,
             client_config,
             fetcher
           ) do
      # Build API-ready objects
      today = Date.utc_today()

      active_objects =
        Enum.map(raw_active, &build_real_estate_object(client_company_id, &1, today, true))
        |> Enum.reject(&is_nil/1)

      inactive_objects =
        Enum.map(raw_inactive, &build_real_estate_object(client_company_id, &1, today, false))
        |> Enum.reject(&is_nil/1)

      Logger.info("Built real estate objects",
        active_count: length(active_objects),
        inactive_count: length(inactive_objects)
      )

      {:ok, {active_objects, inactive_objects}}
    end
  end

  ## Private Functions (matching Go's private functions)

  # Equivalent to Go's `importObjectsXML`
  @spec import_objects_xml(String.t(), boolean(), map(), module()) ::
          {:ok, [object()], [object()]} | {:error, term()}
  defp import_objects_xml(
         client_company_id,
         non_object_specific_account_nos,
         client_config,
         fetcher
       ) do
    endpoint_id = Map.get(client_config, :object_endpoint_id)

    case fetcher.fetch(client_config, endpoint_id) do
      {:ok, xml_data} ->
        case parse_objects_xml(
               client_company_id,
               xml_data,
               non_object_specific_account_nos
             ) do
          {:ok, {active, inactive}} ->
            {:ok, active, inactive}

          {:error, reason} ->
            {:error, "failed to parse master data: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Process and separate objects by record status
  defp process_and_separate_objects(objects) do
    objects
    |> Enum.with_index(2)
    |> Enum.reduce({[], []}, fn {obj, line}, {active_acc, inactive_acc} ->
      # Skip objects with empty or "0000" object number
      if obj.object_nr in ["", "0000"] do
        Logger.warning("Skipping object with empty ObjectNr",
          line: line,
          object_nr: obj.object_nr
        )

        {active_acc, inactive_acc}
      else
        # Clean and validate
        processed_obj = clean_object(obj)

        case validate_object_number(processed_obj.object_nr) do
          :ok ->
            # Log warning for non-active records
            if processed_obj.record_status != @active_record do
              Logger.warning("Skipping non-active OBJECTS",
                account_no: processed_obj.object_nr,
                rec_status: processed_obj.record_status
              )
            end

            # Separate by record status
            if processed_obj.record_status == @active_record do
              {[processed_obj | active_acc], inactive_acc}
            else
              Logger.warning("Inactive objects",
                object_number: processed_obj.object_nr
              )

              {active_acc, [processed_obj | inactive_acc]}
            end

          {:error, reason} ->
            Logger.error("Invalid object number",
              line: line,
              object_nr: processed_obj.object_nr,
              error: reason
            )

            {active_acc, inactive_acc}
        end
      end
    end)
    |> then(fn {active, inactive} ->
      {Enum.reverse(active), Enum.reverse(inactive)}
    end)
  end

  # Clean object data
  defp clean_object(obj) do
    %{
      obj
      | object_nr: String.trim(obj.object_nr),
        location: parse_zip_code(obj.location),
        street: clean_nullable_string(obj.street)
    }
  end

  # Clean nullable string fields (matches Go's structcsv.IsNullString logic)
  defp clean_nullable_string(str) when is_binary(str) do
    trimmed = String.trim(str)

    if trimmed in ["", "NULL", "null", "nil"] do
      ""
    else
      trimmed
    end
  end

  defp clean_nullable_string(_), do: ""

  # Parse ZIP code from location string (matches Go's ParseZipCode)
  defp parse_zip_code(location) when is_binary(location) and byte_size(location) >= 4 do
    case Regex.scan(~r/\b\d{4,5}\b/, location) do
      [] -> ""
      matches -> matches |> List.last() |> hd()
    end
  end

  defp parse_zip_code(_), do: ""

  # Validate object number
  defp validate_object_number(object_nr) when is_binary(object_nr) do
    trimmed = String.trim(object_nr)

    if String.length(trimmed) > 0 do
      :ok
    else
      {:error, "line column ObjektNr has error: empty object number"}
    end
  end

  # Build real estate object for API (matches Go's buildRealEstateObject)
  defp build_real_estate_object(client_company_id, object, _today, active?) do
    object_type = map_object_type(object.typ)
    country_code = determine_country_code(client_company_id, object.location)

    %{
      number: object.object_nr,
      type: object_type,
      street_address: object.street,
      zip_code: object.location,
      country: country_code,
      active: active?
    }
  end

  # Map object type code to atom
  defp map_object_type("0"), do: :hi
  defp map_object_type("1"), do: :weg
  defp map_object_type("2"), do: :sub
  defp map_object_type(_), do: :hi

  # Determine country code (matches Go's logic)
  defp determine_country_code(client_company_id, location) do
    cond do
      client_company_id == "ed8d1964-4cc6-4e8c-a112-4cf3777d7ef0" ->
        "AT"

      String.length(location) == 4 ->
        "AT"

      String.length(location) == 5 ->
        "DE"

      true ->
        "DE"
    end
  end
end
