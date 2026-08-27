# Automations

Work that starts itself: on a clock, on a trigger, or when a watch finds
something.

```bash
patchwork automation list
patchwork automation show "PR feedback"
patchwork automation pause "Morning sweep"
patchwork automation resume "Morning sweep"
patchwork automation delete "Morning sweep"
```

## Creating one

```bash
patchwork automation create --name "PR feedback" --agent @dev-agent \
  --trigger pull-request --action continue-task \
  --instructions "Address review comments, then re-request review."

# Something outside Patchwork starts the work. Creating it prints the URL.
patchwork automation create --name "Bug reports" --agent @dev-agent \
  --trigger webhook --action create-task \
  --instructions "Triage the report in the payload, and fix it if it is small."

# Watch for it yourself: a validated command polled on the relay that wakes an
# agent only for structured events.
patchwork automation create --name "Failed signups" --agent @dev-agent \
  --trigger watch --every 300 --command 'scripts/scan-signup-errors.sh' \
  --action create-task --instructions "Find the cause of what the scan found."
```

An automation created from a conversation stays connected to it, so its
instructions do not need the conversation copied into them.

## Waiting for a task

`--task` narrows a task-status trigger to one task, so you can hand work off
and be woken when it lands instead of watching it:

```bash
patchwork automation create --name "PW-14 follow-up" --agent @me \
  --trigger task-status --status done --task PW-14 --action post-in-chat \
  --instructions "Say here what PW-14 changed, and what is left."
```

It stays enabled until you pause or delete it. Without `--task` the same
trigger watches every task in the workspace.

## Webhooks

`POST {url}` with any JSON body; it becomes the trigger payload. Add
`?once=your-key` and a redelivery of the same event is dropped instead of
acting twice, so whatever calls it is free to retry.

## Watches

The command runs on the relay every `--every` seconds. Exit 0 with empty stdout
is the only healthy no-op: no run, no cost, so checking every minute is fine. A
non-zero exit, a timeout, or non-empty stdout that is not a valid structured
event is a visible failure that retries until you fix or pause the watch.

Write the scan as a script in the project and point the command at it, rather
than cramming it into one line. `$PATCHWORK_STATE_DIR` is a directory kept
between polls. Run `patchwork automation test <name>` after changing a command.

A watch that creates tasks prints one compact JSON object per line:

```json
{"event_key":"deploy-1842","condition_key":"checkout:deploy","title":"Restore checkout deployment","outcome":"Checkout deploys successfully from main","context":{"status":500}}
```

`event_key` identifies one exact delivery and prevents replay. `condition_key`
identifies the durable condition across the workspace and reuses its open task,
so namespace it to its project or source. Diagnostics go to stderr; invalid
output counts as a failure rather than waking anybody.
