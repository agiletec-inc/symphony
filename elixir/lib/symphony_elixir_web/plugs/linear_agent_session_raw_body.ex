defmodule SymphonyElixirWeb.Plugs.LinearAgentSessionRawBody do
  @moduledoc false
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts), do: conn

  @type body_result :: {:ok | :more, binary(), Plug.Conn.t()} | {:error, term()}
  @spec read_body(Plug.Conn.t(), keyword()) :: body_result()
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {status, body, conn} when status in [:ok, :more] ->
        capture_native_body(conn, status, body)

      other ->
        other
    end
  end

  defp capture_native_body(%{request_path: "/api/v1/linear/agent-sessions"} = conn, status, body) do
    accumulated = (conn.private[:linear_raw_body] || "") <> body

    if byte_size(accumulated) <= 1_048_576 do
      {status, body, Plug.Conn.put_private(conn, :linear_raw_body, accumulated)}
    else
      {:error, :too_large}
    end
  end

  defp capture_native_body(conn, status, body), do: {status, body, conn}
end
