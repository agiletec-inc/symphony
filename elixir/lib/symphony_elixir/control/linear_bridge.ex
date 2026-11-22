defmodule SymphonyElixir.Control.LinearBridge do
  @moduledoc "Scoped Linear comment control bridge with injectable GraphQL transport."
  @query """
  query ControlIssueComments($issueId: ID!, $after: String) {
    issue(id: $issueId) { id comments { nodes { id body createdAt user { id } issue { id } } pageInfo { hasNextPage endCursor } } }
  }
  """
  @spec fetch_comments(
          String.t(),
          (String.t(), map() -> {:ok, map()} | {:error, term()})
        ) :: {:ok, [map()]} | {:error, term()}
  def fetch_comments(issue_id, graphql_fun) when is_binary(issue_id) and is_function(graphql_fun, 2) do
    fetch_page(issue_id, nil, graphql_fun, [], [])
  end

  @spec fetch_page(
          String.t(),
          String.t() | nil,
          (String.t(), map() -> {:ok, map()} | {:error, term()}),
          [map()],
          [String.t() | nil]
        ) ::
          {:ok, [map()]} | {:error, term()}
  defp fetch_page(issue_id, cursor, graphql_fun, acc, seen) do
    if repeated_cursor?(cursor, seen),
      do: {:error, :nonprogressing_cursor},
      else: fetch_page_request(issue_id, cursor, graphql_fun, acc, seen)
  end

  @spec fetch_page_request(
          String.t(),
          String.t() | nil,
          (String.t(), map() -> {:ok, map()} | {:error, term()}),
          [map()],
          [String.t() | nil]
        ) ::
          {:ok, [map()]} | {:error, term()}
  defp fetch_page_request(issue_id, cursor, graphql_fun, acc, seen) do
    case graphql_fun.(@query, %{issueId: issue_id, after: cursor}) do
      {:ok, %{"data" => %{"issue" => %{"id" => ^issue_id, "comments" => comments}}}} when is_map(comments) ->
        nodes = comments["nodes"]
        more = get_in(comments, ["pageInfo", "hasNextPage"])
        next = get_in(comments, ["pageInfo", "endCursor"])

        if not is_list(nodes) or not is_boolean(more),
          do: {:error, :invalid_linear_payload},
          else: fetch_page_data(issue_id, cursor, graphql_fun, acc, seen, nodes, more, next)

      {:ok, _} ->
        {:error, :invalid_linear_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec repeated_cursor?(String.t() | nil, [String.t() | nil]) :: boolean()
  defp repeated_cursor?(cursor, seen), do: is_binary(cursor) and cursor in seen

  @spec fetch_page_data(
          String.t(),
          String.t() | nil,
          (String.t(), map() -> {:ok, map()} | {:error, term()}),
          [map()],
          [String.t() | nil],
          [map()],
          boolean(),
          String.t() | nil
        ) ::
          {:ok, [map()]} | {:error, term()}
  defp fetch_page_data(issue_id, cursor, graphql_fun, acc, seen, nodes, more, next) do
    next_acc = acc ++ Enum.map(nodes, &normalize/1)

    cond do
      more and (not is_binary(next) or next == cursor) -> {:error, :nonprogressing_cursor}
      more -> fetch_page(issue_id, next, graphql_fun, next_acc, [cursor | seen])
      true -> {:ok, next_acc}
    end
  end

  @spec command(map(), [String.t()], String.t()) :: {:ok, atom()} | :ignore
  def command(%{id: id, issue_id: issue_id, user_id: user_id, body: body}, actors, controller)
      when is_binary(id) and is_binary(issue_id) and is_binary(body) do
    cond do
      user_id == controller or not Enum.member?(actors, user_id) -> :ignore
      Regex.match?(~r/^\/symphony\s+resume\b/u, String.trim(body)) -> {:ok, :resume}
      Regex.match?(~r/^\/symphony\s+pause\b/u, String.trim(body)) -> {:ok, :pause}
      true -> :ignore
    end
  end

  def command(_, _, _), do: :ignore

  @spec project(
          String.t(),
          map(),
          (String.t(), map() -> {:ok, map()} | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def project(issue_id, snapshot, graphql_fun) when is_binary(issue_id) and is_map(snapshot) and is_function(graphql_fun, 2) do
    stable_id = stable_comment_id(issue_id)
    body = projection_body(snapshot)
    existing = Map.get(snapshot, :comment_id)

    {query, variables} =
      if is_binary(existing) do
        {"mutation ControlComment($id: String!, $input: CommentUpdateInput!) { commentUpdate(id: $id, input: $input) { comment { id } userError } }", %{id: existing, input: %{body: body}}}
      else
        {"mutation ControlComment($input: CommentCreateInput!) { commentCreate(input: $input) { comment { id } userError } }", %{input: %{id: stable_id, issueId: issue_id, body: body}}}
      end

    graphql_fun.(query, variables) |> project_response(existing || stable_id, body)
  end

  defp project_response({:ok, %{"data" => data} = response}, id, body) do
    payload = data["commentCreate"] || data["commentUpdate"]

    if is_map(payload) and payload["userError"] in [[], nil],
      do: {:ok, %{id: id, body: body, response: response}},
      else: {:error, {:projection_pending, :user_error, id}}
  end

  defp project_response({:error, reason}, id, _body), do: {:error, {:projection_pending, reason, id}}

  defp stable_comment_id(issue_id) do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.hash(:md5, "symphony-control:" <> issue_id)
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e]) |> IO.iodata_to_binary()
  end

  defp projection_body(snapshot) do
    fields = [:stage, :summary, :wait_reason, :next_action, :thread_id, :pr_id, :tests, :model]
    Enum.map_join(fields, "\n", fn key -> "#{key}=#{inspect(Map.get(snapshot, key))}" end)
  end

  defp normalize(comment) do
    %{
      id: comment["id"],
      issue_id: get_in(comment, ["issue", "id"]),
      user_id: get_in(comment, ["user", "id"]),
      body: comment["body"],
      created_at: comment["createdAt"]
    }
  end
end
