defmodule SymphonyElixir.Control.ActivityProjection do
  @moduledoc "Fixed operational messages; never accepts conversation text or log content."

  @messages %{
    ready: %{type: "thought", body: "指示を受け付けました。実行を待っています。"},
    running: %{type: "thought", body: "実行を開始しました。"},
    paused: %{type: "elicitation", body: "次の実行は保留中です。実行中の処理には停止を要求しました。再開するには「再開」と入力してください。"},
    waiting_user: %{type: "elicitation", body: "次の指示または判断を、このセッションに入力してください。"},
    waiting_ci: %{type: "thought", body: "CIの結果を待っています。"},
    reviewing: %{type: "thought", body: "レビューを実行しています。"},
    failed: %{type: "error", body: "実行に失敗しました。再開には原因の確認が必要です。"},
    completed: %{type: "response", body: "作業が完了しました。"}
  }

  @spec content(atom()) :: {:ok, %{type: String.t(), body: String.t()}} | :error
  def content(phase), do: Map.fetch(@messages, phase)
end
