defmodule RealDataAPI do
  @moduledoc """
  Module for interacting with the RealData API.

  This module provides functionality to fetch master data from the RealData API
  by first authenticating via a POST request and then retrieving data via a GET request.

  It mimics the behavior of the Go implementation, including handling cookies for session
  management and skipping TLS verification for self-signed certificates.

  ## Configuration

  The configuration is expected to be a map matching the structure from the YAML file.
  Example configuration for a single client:

      %{
        "name" => "krenauer",
        "base_url" => "https://online.krenauer.at/acureal/webreal.acu",
        "username" => "idwell",
        "submit_value" => "register",
        "location_value" => "webreal.acu?id=01",
        "client_company_id" => "ed8d1964-4cc6-4e8c-a112-4cf3777d7ef0",
        "nonObjectSpecificAccountNos" => false,
        "object_endpoint_id" => 80,
        "glAccount_endpoint_id" => 83,
        "partner_endpoint_id" => 82,
        # Password and other sensitive fields should be loaded securely, e.g., from env vars
        "password" => System.fetch_env!("REALDATA_PASSWORD_KRENAUER")
      }

  Multiple clients can be loaded from a YAML file using a library like `yaml_elixir`:

      yaml_content = File.read!("config/realdata_clients.yaml")
      {:ok, config} = YamlElixir.read_from_string(yaml_content)
      clients = config["realdata_clients"]

  Then, you can select a client config by name or index.

  ## Dependencies

  This module uses the `Req` library for HTTP requests, which handles cookies automatically
  via a built-in cookie jar and supports custom transport options.

  Add to your mix.exs:

      {:req, "~> 0.5.0"}
      {:yaml_elixir, "~> 2.9"}  # Optional, for parsing YAML configs

  ## Usage

      config = %{...}  # Load your config
      {:ok, data} = RealDataAPI.fetch(config, 80)
  """

  require Logger

  @doc """
  Fetches data from the specified endpoint ID after authenticating.

  ## Parameters

  - `config`: A map containing the RealDataClientConfig fields.
  - `endpoint_id`: The integer ID of the endpoint to fetch (e.g., object_endpoint_id).

  ## Returns

  - `{:ok, binary()}`: The raw byte response body on success.
  - `{:error, term()}`: Error details on failure.

  This function performs:
  1. Authentication via POST to `base_url?id=01`.
  2. Data fetch via GET to `base_url?id=<endpoint_id>`.

  It uses a single Req client instance to persist cookies between requests.
  TLS verification is skipped for self-signed certificates.
  """
  @spec fetch(map(), integer()) :: {:ok, binary()} | {:error, term()}
  def fetch(config, endpoint_id) do
    # Equivalent to creating a cookie jar and HTTP client in Go.
    # Req.new() creates a request struct with options.
    # transport_opts is used for custom TLS options.
    req =
      Req.new(
        connect_options: [transport_opts: [verify: :verify_none]],  # Skip TLS verification like InsecureSkipVerify: true
        redirect: true,  # Allow automatic redirects (default in Req)
        plug: {Req.Steps, :put_plug_cookie_jar}  # Enable cookie jar for session persistence
      )

    # Form data preparation, equivalent to url.Values in Go.
    form_data = [
      {"httpd_username", config["username"]},
      {"httpd_password", config["password"]},
      {"submit", config["submit_value"]},
      {"httpd_location", config["location_value"]}
    ]

    # Auth URL, equivalent to fmt.Sprintf("%s?id=01", clientConfig.BaseURL)
    auth_url = config["base_url"] <> "?id=01"

    # Perform POST for authentication.
    # Equivalent to http.NewRequestWithContext(ctx, "POST", authURL, ...) and client.Do(req)
    case Req.post(req, url: auth_url, form: form_data, headers: headers(auth_url)) do
      {:ok, %Req.Response{status: 200, body: _}} ->
        Logger.info("Authentication successful")

        # Data URL, equivalent to fmt.Sprintf(clientConfig.BaseURL + "?id=%d", id)
        data_url = config["base_url"] <> "?id=#{endpoint_id}"

        # Perform GET for data.
        # Reuse the same req (with cookies) for the GET.
        case Req.get(req, url: data_url) do
          {:ok, %Req.Response{status: 200, body: body}} ->
            {:ok, body}

          {:ok, %Req.Response{status: status, body: body}} ->
            Logger.error("Data fetch failed", status: status, response_body: body)
            {:error, "data fetch failed: #{status} - #{body}"}

          {:error, reason} ->
            {:error, "error making GET request: #{inspect(reason)}"}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Authentication failed", status: status, response_body: body)
        {:error, "authentication failed: #{status} - #{body}"}

      {:error, reason} ->
        if reason == :cancelled do
          Logger.info("Authentication request canceled")
          {:error, :cancelled}
        else
          {:error, "error making POST request: #{inspect(reason)}"}
        end
    end
  end

  # Helper to set common headers, equivalent to req.Header.Set in Go.
  defp headers(referer) do
    [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"},
      {"Referer", referer}
    ]
  end
end
