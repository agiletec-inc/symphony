# Post-merge completion checks

Symphony must not move a Linear Issue to `Done` from an agent report or from a pull-request
body. After the PR is merged, the host controller must read the merge commit SHA and run:

```sh
node scripts/publish-completion-checks.mjs \
  owner/repository MERGE_COMMIT_SHA /absolute/repository-checkout \
  '["pnpm","acceptance"]' '["pnpm","runtime"]'
```

The command fetches the repository with `git fetch --atomic --prune origin`, creates a detached
temporary worktree at the exact merge commit, runs both argv arrays there, and publishes the
`symphony-acceptance` and `symphony-runtime` GitHub Checks through the host's saved `gh` credential.
The commands are never run in the primary checkout. Both Checks are published even when one
verification fails; any failed verification or publication causes the command to fail.

The command removes token environment variables before invoking `gh`, and updates the latest
existing Check Run for the same name and SHA instead of creating duplicates. The completion
verifier in the consumer repository must require both Checks to be successful and
to have the same merge commit SHA before updating the Linear Issue to `Done`. Missing host
credentials, missing commands, an invalid SHA, a missing commit, or an unavailable worktree
must remain fail-closed. Do not place credentials in command arguments, Issue text, logs, or
artifacts.
