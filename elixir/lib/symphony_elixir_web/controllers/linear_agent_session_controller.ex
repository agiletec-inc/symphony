defmodule SymphonyElixirWeb.LinearAgentSessionController do
  @moduledoc "Native Linear Agent Session ingress."
  use Phoenix.Controller, formats: []

  alias SymphonyElixir.Linear.AgentSession
  alias SymphonyElixir.Linear.Client

  @conflict_errors [:collision, :delivery_body_collision, :unknown_native_session, :native_session_conflict]

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    config = normalize_config(config())

    if truthy?(config[:enabled] || config["enabled"]) do
      dispatch(conn, config)
    else
      send_resp(conn, 404, "not found")
    end
  end

  defp dispatch(conn, config) do
    headers = Map.new(conn.req_headers)
    raw = conn.private[:linear_raw_body] || ""

    case AgentSession.verify(raw, headers, normalize_config(config)) do
      {:ok, event} ->
        with :ok <- authorize_event(event, config),
             :ok <- dedupe_and_dispatch(event, raw, config) do
          send_resp(conn, 200, "ok")
        else
          {:error, :out_of_scope} -> send_resp(conn, 403, "forbidden")
          {:error, :scope_unavailable} -> send_resp(conn, 503, "scope unavailable")
          {:error, reason} when reason in @conflict_errors -> send_resp(conn, 409, "delivery rejected")
          {:error, _} -> send_resp(conn, 503, "control unavailable")
        end

      {:error, :invalid_signature} ->
        send_resp(conn, 401, "unauthorized")

      {:error, :out_of_scope} ->
        send_resp(conn, 403, "forbidden")

      {:error, _} ->
        send_resp(conn, 400, "invalid webhook")
    end
  end

  defp dedupe_and_dispatch(event, raw, config) do
    server = config[:control_server] || config["control_server"] || SymphonyElixir.Control
    delivery = event["_delivery"]
    hash = :crypto.hash(:sha256, raw)

    session = event["agentSession"]
    normalized = Map.put(event, "agentSession", Map.put(session, "issue", Map.put(session["issue"] || %{}, "id", AgentSession.issue_id(event))))

    SymphonyElixir.Control.accept_native(server, Map.put(normalized, "_delivery", delivery), hash,
      graphql_client: graphql_client(config),
      interrupt: config[:interrupt] || config["interrupt"]
    )
  end

  defp authorize_event(event, config) do
    if get_in(event, ["agentActivity", "signal"]) == "stop" do
      server = config[:control_server] || SymphonyElixir.Control
      record = SymphonyElixir.Control.snapshot(server, AgentSession.issue_id(event))
      if record[:native_session_id] == get_in(event, ["agentSession", "id"]), do: :ok, else: {:error, :unknown_native_session}
    else
      AgentSession.authorize(event, config, graphql_client(config))
    end
  end

  defp config do
    endpoint = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    Keyword.get(endpoint, :linear_agent_session_control) || native_settings()
  end

  defp native_settings do
    settings = SymphonyElixir.Config.settings!().linear_agent_session
    Map.from_struct(settings)
  end

  defp normalize_config(config) when is_map(config), do: config
  defp normalize_config(config) when is_list(config), do: Map.new(config)

  defp graphql_client(config) do
    config[:graphql_client] ||
      fn query, variables, opts ->
        Client.graphql(query, variables, Keyword.put(opts, :request_timeout_ms, 1_000))
      end
  end

  defp truthy?(value), do: value == true
end
