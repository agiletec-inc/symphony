defmodule SymphonyElixir.ControlProtocolAcceptanceTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Control

  test "terminal handoff forks a clean isolated thread and pins model for review" do
    assert {:ok, request} =
             Control.protocol_request(:terminal_handoff, %{
               thread_id: "thread-source",
               cwd: "/tmp/clean-source",
               model: "gpt-5.6-luna",
               source_head: "abc123",
               source_dirty: false
             })

    assert request.method == "thread/fork"
    assert request.params["threadId"] == "thread-source"
    assert request.params["cwd"] != "/tmp/clean-source"
    assert request.params["model"] == "gpt-5.6-luna"

    assert {:ok, review} = Control.protocol_request(:review, %{thread_id: "thread-new", model: "gpt-5.6-luna"})
    assert review.method == "thread/start"
    assert review.params["model"] == "gpt-5.6-luna"
    assert review.params["cwd"] != request.params["cwd"]
  end

  test "dirty source and unavailable model are rejected" do
    assert {:error, :dirty_source} =
             Control.protocol_request(:terminal_handoff, %{thread_id: "t", source_dirty: true})

    assert {:error, :model_unavailable} =
             Control.protocol_request(:review, %{thread_id: "t", model: "missing-model"})
  end

  test "resume uses the official thread/resume seam and no rollout parsing" do
    assert {:ok, request} = Control.protocol_request(:resume, %{thread_id: "thread-controller", model: "gpt-5.6-luna"})
    assert request.method == "thread/resume"
    assert request.params["threadId"] == "thread-controller"
    refute Map.has_key?(request.params, :rollout)
    refute Map.has_key?(request.params, "rollout")
  end

  test "CI pending does not wake; terminal transition wakes exactly once" do
    issue_id = "issue-ci-#{System.unique_integer([:positive])}"
    assert {:ok, :pending} = Control.ci_event(issue_id, %{status: :unknown})
    assert {:ok, :pending} = Control.ci_event(issue_id, %{status: :pending})
    assert {:ok, :wake} = Control.ci_event(issue_id, %{status: :completed})
    assert {:duplicate, :wake} = Control.ci_event(issue_id, %{status: :completed})
    assert {:error, :provider_failed} = Control.ci_event(issue_id, %{status: :provider_failed})
  end
end
