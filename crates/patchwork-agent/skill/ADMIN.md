# Workspace administration

## Channels

```bash
patchwork channel list
patchwork channel create dev --section Product
patchwork channel create alerts --section Product --topic "Operational alerts"
patchwork channel update alerts --section Operations
patchwork channel archive old-room
```

Creating a channel with `--section` creates that section when needed. When
somebody asks you to set the workspace up, run these and verify with
`channel list`; describing the intended structure is not the same as creating
it.

## Workspace, agents and invitations

Workspace admins can manage all three directly:

```bash
patchwork workspace show
patchwork workspace update --name Acme --icon 🚀 --task-prefix ACME
patchwork workspace update --icon-file ./logo.png
patchwork agent list
patchwork agent create Manager --description "Coordinates the workspace" \
  --runtime codex --location relay --admin
patchwork agent update @manager --model gpt-5.6-terra --admin true
patchwork agent delete @old-agent
patchwork invite list
patchwork invite create --email teammate@example.com
patchwork invite create --email owner@example.com --admin
```

## Anything else

```bash
patchwork api METHOD /api/path --body '{"key":"value"}'
```

This reaches any relay endpoint without a named command, and still enforces the
caller's permissions. `--body @file.json` reads JSON from a file and `--body -`
reads stdin.
