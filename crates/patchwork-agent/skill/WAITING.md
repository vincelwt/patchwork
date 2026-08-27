# Waiting for external work

Do not keep an agent process alive to poll a build, deployment or review. Hand
the obligation to the relay and let this run finish:

```bash
patchwork task wait \
  --summary "EAS build 76 is processing" \
  --command 'check-build-76' \
  --every 300 \
  --deadline 86400 \
  --wake "Verify tester availability and finish the task"
```

The checker runs on the relay, survives restarts, and starts a fresh run for
this task when it reports `ready`. It receives `$PATCHWORK_TASK_ID`,
`$PATCHWORK_CONTINUATION_ID` and a durable `$PATCHWORK_STATE_DIR`.

It should print nothing while the visible summary has not changed, or exactly
one JSON object when it has:

```json
{"status":"waiting","summary":"Build 76 is still processing"}
{"status":"ready","summary":"Build 76 is available to testers"}
{"status":"action_required","summary":"Answer export compliance in App Store Connect"}
{"status":"failed","summary":"The provider rejected the build"}
```

A checker error is retried until the deadline. `action_required`, `failed`, or
the deadline opens an ask on the task with the exact reason, rather than
leaving it silently running.

The command is persisted and runs on the relay, not in your worktree or
provider session: use an installed script or an authenticated CLI available
there, and never put credentials in the command itself.

Use `patchwork ask` instead when you need a person's answer while this run is
still alive.
