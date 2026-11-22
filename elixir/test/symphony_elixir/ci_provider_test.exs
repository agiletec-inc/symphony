defmodule SymphonyElixir.Control.CiProviderTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Control.CiProvider

  @repo "owner/repo"
  @url "https://github.com/owner/repo/pull/7"
  @sha String.duplicate("a", 40)

  defp workspace do
    root = Path.join(System.tmp_dir!(), "ci-provider-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp command(head \\ @sha, remote \\ "git@github.com:owner/repo.git", payload \\ nil) do
    payload =
      payload || Jason.encode!(%{"headRefOid" => @sha, "statusCheckRollup" => [%{"__typename" => "CheckRun", "status" => "COMPLETED", "conclusion" => "SUCCESS"}], "number" => 7, "url" => @url})

    fn executable, args, _cwd ->
      case {executable, args} do
        {"git", ["rev-parse", "HEAD"]} -> {:ok, head}
        {"git", ["remote", "get-url", "origin"]} -> {:ok, remote}
        {"git", ["symbolic-ref", "--quiet", "--short", "HEAD"]} -> {:ok, "feature/test"}
        {"gh", ["pr", "view", "feature/test", "--repo", @repo, "--json", "headRefOid,statusCheckRollup,number,url"]} -> {:ok, payload}
        _ -> {:error, :unexpected_command}
      end
    end
  end

  test "captures a validated provider payload and exact command cwd" do
    root = workspace()
    calls = start_supervised!({Agent, fn -> [] end})

    cmd = fn executable, args, cwd ->
      Agent.update(calls, &[{executable, args, cwd} | &1])
      command().(executable, args, cwd)
    end

    assert {:ok, %{"headRefOid" => @sha, "url" => @url}} = CiProvider.capture(root, command: cmd)
    assert Enum.all?(Agent.get(calls, & &1), &(elem(&1, 2) == root))
  end

  test "rejects wrong head and wrong repository" do
    root = workspace()
    assert {:error, _} = CiProvider.capture(root, command: command(String.duplicate("b", 40)))
    assert {:error, _} = CiProvider.capture(root, command: command(@sha, "https://github.com/other/repo.git"))
  end

  test "rejects a changed HEAD" do
    root = workspace()
    counter = start_supervised!({Agent, fn -> 0 end})

    cmd = fn executable, args, cwd ->
      if {executable, args} == {"git", ["rev-parse", "HEAD"]} do
        n = Agent.get_and_update(counter, &{&1, &1 + 1})
        command(if(n == 0, do: @sha, else: String.duplicate("b", 40))).(executable, args, cwd)
      else
        command().(executable, args, cwd)
      end
    end

    assert {:error, _} = CiProvider.capture(root, command: cmd)
  end

  test "unsafe remote or saved PR from another repository is rejected before gh" do
    root = workspace()

    for remote <- ["https://user:password@github.com/owner/repo.git", "https://evil.example/owner/repo", "https://github.com/owner/repo?query=x"] do
      cmd = fn
        "gh", _, _ -> flunk("gh must not run for an untrusted origin")
        exe, args, cwd -> command(@sha, remote).(exe, args, cwd)
      end

      assert {:error, :unsupported_ci_remote} = CiProvider.capture(root, command: cmd)
    end

    cmd = fn
      "gh", _, _ -> flunk("gh must not query a different repository")
      exe, args, cwd -> command().(exe, args, cwd)
    end

    assert {:error, :ci_workspace_mismatch} = CiProvider.poll(root, %{pr_url: "https://github.com/other/repo/pull/7", head_sha: @sha}, command: cmd)
  end

  test "native command path fails closed for a repository without a commit" do
    root = workspace()
    assert {_, 0} = System.cmd("git", ["init", "--quiet", root], stderr_to_stdout: true)
    assert {:error, :ci_git_failed} = CiProvider.capture(root)
  end

  test "propagates malformed JSON and gh errors" do
    root = workspace()
    assert {:error, _} = CiProvider.capture(root, command: command(@sha, "git@github.com:owner/repo.git", "bad"))

    failing = fn
      "gh", _, _ -> {:error, :gh_failed}
      exe, args, cwd -> command().(exe, args, cwd)
    end

    assert {:error, :gh_failed} = CiProvider.capture(root, command: failing)
  end
end
