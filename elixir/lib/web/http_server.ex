defmodule Web.HttpServer do
  @moduledoc """
  Supervises the Phoenix observability endpoint. Configuration (port, host,
  secret_key_base, orchestrator, snapshot_timeout_ms) is expected to be in
  `Application.get_env(:core, Web.Endpoint)` — populated by `config/config.exs`
  for defaults and `config/runtime.exs` for workflow-driven values.

  Opts passed to `start_link/1` override endpoint config for the duration of
  the invocation (used by tests to override per-run values like orchestrator
  or port). Production callers pass no opts and rely on the configured state.
  """

  alias Web.Endpoint

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    with {:ok, endpoint_config} <- resolve_endpoint_config(opts) do
      if endpoint_config[:server] do
        Application.put_env(:core, Endpoint, endpoint_config)
        Endpoint.start_link()
      else
        :ignore
      end
    end
  end

  defp resolve_endpoint_config(opts) do
    base = Application.get_env(:core, Endpoint, [])

    with {:ok, http_config} <- resolve_http_config(opts, base) do
      overrides =
        opts
        |> Keyword.take([:orchestrator, :snapshot_timeout_ms])
        |> Keyword.merge(
          if http_config, do: [server: true, http: http_config], else: []
        )

      {:ok, Keyword.merge(base, overrides)}
    end
  end

  defp resolve_http_config(opts, base) do
    case Keyword.get(opts, :port) do
      nil ->
        {:ok, Keyword.get(base, :http)}

      port when is_integer(port) and port >= 0 ->
        host = Keyword.get(opts, :host, "127.0.0.1")

        with {:ok, ip} <- parse_host(host) do
          {:ok, [ip: ip, port: port]}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp parse_host({_, _, _, _} = ip), do: {:ok, ip}
  defp parse_host({_, _, _, _, _, _, _, _} = ip), do: {:ok, ip}

  defp parse_host(host) when is_binary(host) do
    charhost = String.to_charlist(host)

    case :inet.parse_address(charhost) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _reason} ->
        case :inet.getaddr(charhost, :inet) do
          {:ok, ip} -> {:ok, ip}
          {:error, _reason} -> :inet.getaddr(charhost, :inet6)
        end
    end
  end
end
