---
tracker:
  kind: memory
  required_labels:
    - symphony-pilot
  active_states:
    - Todo
    - In Progress
    - Rework
  terminal_states:
    - Done
    - Cancelled
    - Canceled
    - Duplicate
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
agent:
  max_concurrent_agents: 1
codex:
  command: codex app-server
  approval_policy:
    reject:
      sandbox_approval: true
      rules: true
      mcp_elicitations: true
  thread_sandbox: workspace-write
---

Authentication-free synthetic configuration test. The memory tracker contains no issues.
