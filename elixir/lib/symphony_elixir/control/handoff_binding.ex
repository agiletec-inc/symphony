defmodule SymphonyElixir.Control.HandoffBinding do
  @moduledoc "Scoped native session attachment for imported Terminal work."
  alias SymphonyElixir.{Control, Linear.AgentSession, Linear.TerminalSession}

  @spec resolve(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def resolve(request, opts) do
    config = Keyword.fetch!(opts, :config)

    if config[:enabled] == true do
      with {:ok, target} <- TerminalSession.resolve_issue(request.issue_id, config, Keyword.fetch!(opts, :graphql)) do
        {:ok, Map.put(request, :issue_id, target.issue_id)}
      end
    else
      {:ok, request}
    end
  end

  @spec connect(GenServer.server(), String.t(), keyword()) :: :ok | {:error, atom()}
  def connect(owner, issue, opts) do
    config = Keyword.fetch!(opts, :config)
    graphql = Keyword.fetch!(opts, :graphql)

    if config[:enabled] == true do
      case Control.prepare_terminal_session(owner, issue) do
        :create ->
          create_binding(owner, issue, config, graphql)

        {:existing, session} ->
          existing_binding(owner, issue, session, config, graphql)

        {:error, _} = error ->
          error
      end
    else
      :ok
    end
  end

  defp existing_binding(owner, issue, session, config, graphql) do
    bounded = fn query, variables, call_opts -> graphql.(query, variables, Keyword.put(call_opts, :request_timeout_ms, 1_000)) end

    with :ok <- AgentSession.authorize(%{"agentSession" => %{"id" => session, "issue" => %{"id" => issue}}}, config, bounded),
         do: bind_if_pending(owner, issue, session, graphql)
  end

  defp create_binding(owner, issue, config, graphql) do
    with {:ok, session} <- TerminalSession.create_session(issue, config, graphql),
         do: Control.bind_terminal_session(owner, issue, session, graphql_client: graphql)
  end

  defp bind_if_pending(owner, issue, session, graphql) do
    if Control.snapshot(owner, issue)[:session_creation_pending] == true,
      do: Control.bind_terminal_session(owner, issue, session, graphql_client: graphql),
      else: :ok
  end
end
