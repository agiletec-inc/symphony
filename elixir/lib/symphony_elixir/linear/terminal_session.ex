defmodule SymphonyElixir.Linear.TerminalSession do
  @moduledoc "Small, scope-checked GraphQL boundary for terminal sessions."

  @resolve_query "query TerminalSessionResolve($id: String!) { viewer { id organization { id } } issue(id: $id) { id identifier project { id } } }"
  @create_mutation "mutation TerminalSessionCreate($input: AgentSessionCreateOnIssue!) { agentSessionCreateOnIssue(input: $input) { success agentSession { id appUser { id } issue { id project { id } } } } }"

  @type graphql :: (String.t(), map(), keyword() -> term())
  @type resolution_error :: :disabled | :out_of_scope | :scope_unavailable
  @type creation_error :: :disabled | :session_creation_unresolved

  @spec resolve_issue(String.t(), map(), graphql()) :: {:ok, map()} | {:error, resolution_error()}
  def resolve_issue(reference, config, graphql) when is_binary(reference) and is_map(config) and is_function(graphql, 3) do
    if enabled?(config) and scoped_config?(config) do
      response = graphql.(@resolve_query, %{id: reference}, timeout_opts())
      resolve_response(response, config)
    else
      {:error, :disabled}
    end
  rescue
    _ -> {:error, :scope_unavailable}
  end

  defp resolve_response({:ok, %{"errors" => [_ | _]}}, _config), do: {:error, :scope_unavailable}

  defp resolve_response({:ok, %{"data" => %{"viewer" => viewer, "issue" => issue}}}, config) do
    validate_resolved(viewer, issue, config)
  end

  defp resolve_response(_response, _config), do: {:error, :scope_unavailable}

  defp validate_resolved(%{"id" => app, "organization" => %{"id" => org}}, %{"id" => id, "identifier" => identifier, "project" => %{"id" => project}}, config)
       when is_binary(id) and is_binary(identifier) do
    expected = {value(config, :application_user_id), value(config, :organization_id), value(config, :project_id)}

    if {app, org, project} == expected do
      {:ok, %{issue_id: id, identifier: identifier}}
    else
      {:error, :out_of_scope}
    end
  end

  defp validate_resolved(_viewer, _issue, _config), do: {:error, :scope_unavailable}

  @spec create_session(String.t(), map(), graphql()) :: {:ok, String.t()} | {:error, creation_error()}
  def create_session(issue_id, config, graphql) when is_binary(issue_id) and is_map(config) and is_function(graphql, 3) do
    if enabled?(config) and scoped_config?(config) do
      case graphql.(@create_mutation, %{input: %{issueId: issue_id}}, timeout_opts()) do
        {:ok, %{"data" => %{"agentSessionCreateOnIssue" => %{"success" => true}}, "errors" => [_ | _]}} -> {:error, :session_creation_unresolved}
        {:ok, %{"data" => %{"agentSessionCreateOnIssue" => %{"success" => true, "agentSession" => session}}}} -> validate_created(session, issue_id, config)
        _ -> {:error, :session_creation_unresolved}
      end
    else
      {:error, :disabled}
    end
  rescue
    _ -> {:error, :session_creation_unresolved}
  end

  defp validate_created(%{"id" => id, "appUser" => %{"id" => app}, "issue" => %{"id" => issue, "project" => %{"id" => project}}}, issue_id, config)
       when is_binary(id) and byte_size(id) > 0 and issue == issue_id do
    if app == value(config, :application_user_id) and project == value(config, :project_id) do
      {:ok, id}
    else
      {:error, :session_creation_unresolved}
    end
  end

  defp validate_created(_, _, _), do: {:error, :session_creation_unresolved}
  defp enabled?(config), do: value(config, :enabled) == true
  defp scoped_config?(config), do: Enum.all?([:application_user_id, :organization_id, :project_id], &(is_binary(value(config, &1)) and byte_size(value(config, &1)) > 0))
  defp value(config, key), do: Map.get(config, key, Map.get(config, Atom.to_string(key)))
  defp timeout_opts, do: [request_timeout_ms: 1_000, retry: false]
end
