defmodule SymphonyElixir.HandoffInboxTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias SymphonyElixir.Control.HandoffInbox

  test "submits a private durable request and reports its metadata" do
    root = Path.join("/private/tmp", "handoff-inbox-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    source = Path.join(root, "workspace")
    summary = Path.join(root, "summary.json")
    File.mkdir_p!(source)
    File.write!(summary, "{}")

    assert {:ok, id} =
             HandoffInbox.submit(root, %{
               source_workspace: source,
               issue_id: "ISSUE-1",
               thread_id: "thread-1",
               summary_file: summary
             })

    assert {:ok, %{"request_id" => ^id, "status" => "queued"}} = HandoffInbox.status(root, id)
    refute File.exists?(Path.join(root, "handoff-inbox/queued/#{id}.json.tmp"))
    assert (File.stat!(Path.join(root, "handoff-inbox")).mode &&& 0o777) == 0o700
  end

  test "runs one importer and records completion" do
    root = Path.join("/private/tmp", "handoff-inbox-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    source = Path.join(root, "workspace")
    summary = Path.join(root, "summary.json")
    File.mkdir_p!(source)
    File.write!(summary, "{}")
    parent = self()

    importer = fn request, _opts ->
      send(parent, {:imported, request["issue_id"]})
      :ok
    end

    assert {:ok, id} =
             HandoffInbox.submit(root, %{
               source_workspace: source,
               issue_id: "ISSUE-2",
               thread_id: "thread-2",
               summary_file: summary
             })

    {:ok, pid} = HandoffInbox.start_link(state_root: root, owner: self(), importer: importer, interval_ms: 1)
    assert_receive {:imported, "ISSUE-2"}, 1_000

    assert eventually(fn ->
             match?({:ok, %{"request_id" => ^id, "status" => "complete"}}, HandoffInbox.status(root, id))
           end)

    Process.exit(pid, :normal)
  end

  test "recovers importing requests as unknown without importing them" do
    root = Path.join("/private/tmp", "handoff-inbox-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    source = Path.join(root, "workspace")
    summary = Path.join(root, "summary.json")
    File.mkdir_p!(source)
    File.write!(summary, "{}")

    assert {:ok, id} =
             HandoffInbox.submit(root, %{
               source_workspace: source,
               issue_id: "ISSUE-3",
               thread_id: "thread-3",
               summary_file: summary
             })

    File.mkdir_p!(Path.join(root, "handoff-inbox/importing"))

    File.rename!(
      Path.join(root, "handoff-inbox/queued/#{id}.json"),
      Path.join(root, "handoff-inbox/importing/#{id}.json")
    )

    owner = self()

    {:ok, pid} =
      HandoffInbox.start_link(
        state_root: root,
        owner: owner,
        importer: fn _, _ ->
          send(owner, :unexpected)
          :ok
        end,
        interval_ms: 1
      )

    assert eventually(fn -> match?({:ok, %{"status" => "unknown"}}, HandoffInbox.status(root, id)) end)
    refute_received :unexpected
    Process.exit(pid, :normal)
  end

  test "quarantines malformed queued JSON" do
    root = Path.join("/private/tmp", "handoff-inbox-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, _} =
             HandoffInbox.submit(root, %{
               source_workspace: Path.join(root, "w"),
               issue_id: "ISSUE-4",
               thread_id: "t",
               summary_file: Path.join(root, "s")
             })

    queue = Path.join(root, "handoff-inbox/queued")
    file = queue |> File.ls!() |> List.first()
    File.write!(Path.join(queue, file), "not json")

    pid =
      start_supervised!(
        {HandoffInbox,
         state_root: root,
         owner: self(),
         importer: fn _, _ ->
           send(self(), :unexpected)
           :ok
         end,
         interval_ms: 1}
      )

    assert eventually(fn -> File.exists?(Path.join(root, "handoff-inbox/failed/#{file}")) end)
    assert {:ok, %{"status" => "failed"}} = HandoffInbox.status(root, Path.rootname(file))
    refute_received :unexpected
    Process.exit(pid, :normal)
  end

  test "does not consume a symlink queue entry" do
    root = Path.join("/private/tmp", "handoff-inbox-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(Path.join(root, "handoff-inbox/queued"))
    id = "11111111-1111-4111-8111-111111111111"
    target = Path.join(root, "outside.json")
    File.write!(target, Jason.encode!(%{"request_id" => id, "status" => "queued"}))
    File.ln_s!(target, Path.join(root, "handoff-inbox/queued/#{id}.json"))

    pid =
      start_supervised!(
        {HandoffInbox,
         state_root: root,
         owner: self(),
         importer: fn _, _ ->
           send(self(), :unexpected)
           :ok
         end,
         interval_ms: 1}
      )

    Process.sleep(30)
    refute_received :unexpected
    Process.exit(pid, :normal)
  end

  test "records importer errors as failed" do
    root = Path.join("/private/tmp", "handoff-inbox-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, id} =
             HandoffInbox.submit(root, %{
               source_workspace: Path.join(root, "w"),
               issue_id: "ISSUE-5",
               thread_id: "t",
               summary_file: Path.join(root, "s")
             })

    inbox_opts = [state_root: root, owner: self(), importer: fn _, _ -> {:error, :failure} end, interval_ms: 1]
    pid = start_supervised!({HandoffInbox, inbox_opts})

    assert eventually(fn ->
             match?({:ok, %{"status" => "failed", "error" => "import_failed"}}, HandoffInbox.status(root, id))
           end)

    Process.exit(pid, :normal)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    case fun.() do
      true ->
        true

      _ ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
