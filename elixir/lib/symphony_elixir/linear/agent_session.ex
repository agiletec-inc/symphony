defmodule SymphonyElixir.Linear.AgentSession do
  @moduledoc "Verification and scope checks for Linear Agent Session webhooks."
  @timestamp_window_ms 60_000
  @scope_query "query SymphonyNativeScope($id: String!) { agentSession(id: $id) { id appUser { id } issue { id project { id } } } }"

  @spec verify(binary(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def verify(raw, headers, config) when is_binary(raw) and is_map(headers) and is_map(config) do
    with :ok <- valid_signature(raw, headers["linear-signature"], config[:webhook_secret]),
         :ok <- valid_delivery(headers["linear-delivery"]),
         {:ok, event} when is_map(event) <- Jason.decode(raw),
         :ok <- valid_timestamp(event["webhookTimestamp"]),
         :ok <- valid_event(event),
         :ok <- scoped?(event, config) do
      {:ok, Map.put(event, "_delivery", headers["linear-delivery"])}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_event}
    end
  end

  @spec authorize(map(), map(), (String.t(), map(), keyword() -> term())) :: :ok | {:error, atom()}
  def authorize(event, config, graphql) do
    session_id = get_in(event, ["agentSession", "id"])
    issue_id = issue_id(event)
    app_id = config[:application_user_id]
    project_id = config[:project_id]

    expected = {session_id, app_id, issue_id, project_id}
    authorize_response(graphql.(@scope_query, %{id: session_id}, []), expected)
  rescue
    _ -> {:error, :scope_unavailable}
  end

  defp authorize_response({:ok, %{"data" => %{"agentSession" => session}} = response}, expected) when is_map(session) do
    if authoritative_scope?(session, expected) do
      case response do
        %{"errors" => [_ | _]} -> {:error, :scope_unavailable}
        _ -> :ok
      end
    else
      {:error, :out_of_scope}
    end
  end

  defp authorize_response(_response, _expected), do: {:error, :scope_unavailable}

  defp authoritative_scope?(%{"id" => id, "appUser" => %{"id" => app}, "issue" => issue}, expected) do
    case issue do
      %{"id" => issue_id, "project" => %{"id" => project}} -> {id, app, issue_id, project} === expected
      _ -> false
    end
  end

  defp authoritative_scope?(_session, _expected), do: false

  @spec issue_id(map()) :: String.t() | nil
  def issue_id(%{"agentSession" => session}) do
    session["issueId"] || get_in(session, ["issue", "id"])
  end

  defp valid_delivery(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i, value), do: :ok, else: {:error, :invalid_delivery}
  end

  defp valid_delivery(_), do: {:error, :invalid_delivery}

  defp valid_timestamp(value) when is_number(value) do
    if abs(System.system_time(:millisecond) - value) <= @timestamp_window_ms, do: :ok, else: {:error, :stale_timestamp}
  end

  defp valid_timestamp(_), do: {:error, :invalid_timestamp}

  defp valid_signature(raw, signature, secret) when is_binary(signature) and is_binary(secret) and byte_size(secret) > 0 do
    expected = :crypto.mac(:hmac, :sha256, secret, raw) |> Base.encode16(case: :lower)

    if byte_size(signature) == 64 and Plug.Crypto.secure_compare(String.downcase(signature), expected) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp valid_signature(_, _, _), do: {:error, :invalid_signature}

  defp scoped?(event, config) do
    checks = [{"organizationId", :organization_id}, {"appUserId", :application_user_id}, {"oauthClientId", :oauth_client_id}]
    project = config[:project_id]
    claimed_project = get_in(event, ["agentSession", "issue", "projectId"])
    matches = Enum.all?(checks, fn {key, setting} -> nonempty?(config[setting]) and event[key] == config[setting] end)
    if matches and nonempty?(project) and claimed_project in [nil, project], do: :ok, else: {:error, :out_of_scope}
  end

  defp valid_event(%{"type" => "AgentSessionEvent", "action" => action, "agentSession" => session} = event) when action in ["created", "prompted"] and is_map(session) do
    issue = session["issue"]
    valid_issue = valid_issue_shape?(session, issue)

    if valid_issue and nonempty?(session["id"]) and nonempty?(issue_id(event)) and valid_activity?(action, event["agentActivity"]) and
         (is_nil(event["promptContext"]) or is_binary(event["promptContext"])) do
      :ok
    else
      {:error, :invalid_event}
    end
  end

  defp valid_event(_), do: {:error, :invalid_event}

  defp valid_issue_shape?(session, issue) do
    (is_nil(issue) or is_map(issue)) and consistent_issue?(session, issue)
  end

  defp consistent_issue?(%{"issueId" => id}, %{"id" => other}), do: id == other
  defp consistent_issue?(_, _), do: true
  defp valid_activity?("created", _), do: true
  defp valid_activity?("prompted", %{"id" => id, "content" => %{"type" => "prompt", "body" => body}}), do: nonempty?(id) and is_binary(body)
  defp valid_activity?(_, _), do: false
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
end
