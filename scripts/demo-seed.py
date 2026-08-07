#!/usr/bin/env python3
"""Seed a demo workspace with believable data, for screenshots and first runs.

Starts a relay on port 7799 with a fresh data dir, fills it through the same
HTTP API the app uses, and leaves the relay running. Prints the workspace id
and a member token for the browser at the end.

    python3 scripts/demo-seed.py
"""

import base64
import hashlib
import json
import os
import secrets
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELAY = os.path.join(ROOT, "target", "debug", "patchwork-relay")
DATA = "/tmp/patchwork-demo"
PORT = 7799
BASE = f"http://127.0.0.1:{PORT}"
NOW = int(time.time() * 1000)


def minutes_ago(m):
    return NOW - int(m * 60_000)


def days_ago(d):
    return NOW - int(d * 86_400_000)


# --- tiny http client -------------------------------------------------------

def call(method, path, token=None, body=None):
    url = BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("content-type", "application/json")
    if token:
        req.add_header("authorization", f"Bearer {token}")
    with urllib.request.urlopen(req) as response:
        return json.loads(response.read())


def api(ws, method, path, token, body=None):
    return call(method, f"/w/{ws}{path}", token, body)


# --- boot -------------------------------------------------------------------

shutil.rmtree(DATA, ignore_errors=True)
relay = subprocess.Popen(
    [RELAY, "--data-dir", DATA, "--port", str(PORT), "--workspace-name", "Meridian"],
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
)
invite = None
deadline = time.time() + 30
while time.time() < deadline:
    line = relay.stdout.readline()
    if "Invite code:" in line:
        invite = line.split("Invite code:")[1].strip()
        break
assert invite, "relay never printed an invite code"

vince_auth = call("POST", "/api/auth/join", body={"invite_code": invite, "display_name": "Vince"})
WS = vince_auth["workspace"]["id"]
vince = vince_auth["token"]
vince_id = vince_auth["member"]["id"]
DB = os.path.join(DATA, "workspaces", WS, "patchwork.db")

# Task keys should read like a workspace with history.
db = sqlite3.connect(DB)
db.execute("UPDATE workspace SET task_prefix = 'MER', task_seq = 32")
db.commit()


def join_human(name):
    code = api(WS, "POST", "/api/invites", vince, {})["code"]
    auth = call("POST", "/api/auth/join", body={"invite_code": code, "display_name": name})
    return auth["member"]["id"], auth["token"]


maya_id, maya = join_human("Maya Chen")
jonas_id, jonas = join_human("Jonas Richter")

# --- agents -----------------------------------------------------------------
# Created silent (participation off) so seeding never triggers real runs;
# their real participation is switched on at the end.

def make_agent(name, handle, avatar, runtime, description):
    member = api(WS, "POST", "/api/agents", vince, {
        "display_name": name,
        "handle": handle,
        "avatar": avatar,
        "profile": {
            "description": description,
            "runtime": runtime,
            "location": "relay",
            "dm_enabled": False,
            "default_participation": "off",
        },
    })
    token = secrets.token_urlsafe(32)
    digest = base64.urlsafe_b64encode(hashlib.sha256(token.encode()).digest()).rstrip(b"=").decode()
    db.execute(
        "INSERT INTO tokens (token_hash, member_id, kind, label, created_at) VALUES (?,?,?,?,?)",
        (digest, member["id"], "device", "seed", NOW),
    )
    db.commit()
    return member["id"], token


iris_id, iris = make_agent(
    "Iris", "iris", "🌿", "codex",
    "Product engineer. Ships features end to end: repro, fix, tests, PR. "
    "Asks before touching schemas, money, or anything irreversible.",
)
scout_id, scout = make_agent(
    "Scout", "scout", "🔭", "claude",
    "Support and triage. Reads every ticket, files tasks, drafts replies, "
    "and only escalates when a human decision is actually needed.",
)
sable_id, sable = make_agent(
    "Sable", "sable", "⚙️", "pi",
    "Operations. Deploys, monitors, verifies backups, and posts to #deploys. "
    "Rolls back first, explains second.",
)
quill_id, quill = make_agent(
    "Quill", "quill", "🪶", "claude",
    "Docs and changelog. Turns merged PRs into changelog entries and keeps "
    "the help center matching what shipped.",
)

# --- channels ---------------------------------------------------------------

def channel(name, topic, section=None):
    body = {"name": name, "topic": topic}
    if section:
        body["section_name"] = section
    return api(WS, "POST", "/api/channels", vince, body)["id"]


# The relay creates #general with every workspace; give it a topic.
general = next(c for c in api(WS, "GET", "/api/channels", vince) if c["slug"] == "general")["id"]
api(WS, "PATCH", f"/api/channels/{general}", vince, {"topic": "The whole team, humans and agents"})
product = channel("product", "What we build and why", "Product")
design = channel("design", "Flows, screens, copy", "Product")
dev = channel("dev", "Implementation talk", "Engineering")
deploys = channel("deploys", "Every release, posted by Sable", "Engineering")
bugs = channel("bugs", "Repros in, fixes out", "Engineering")
support = channel("support", "Tickets and triage — Scout watches this room", "Operations")
growth = channel("growth", "Numbers and experiments", "Operations")

# --- projects ---------------------------------------------------------------

app_project = api(WS, "POST", "/api/projects", vince, {
    "name": "meridian-app",
    "description": "The Meridian web app and API",
    "repo_url": "https://github.com/meridianhq/meridian",
})["id"]
site_project = api(WS, "POST", "/api/projects", vince, {
    "name": "marketing-site",
    "description": "meridian.fit",
    "repo_url": "https://github.com/meridianhq/site",
})["id"]

# --- tasks ------------------------------------------------------------------

def task(token, title, outcome, status, owner, project=None, source=None, created_days_ago=7.0):
    body = {"title": title, "outcome": outcome, "status": status, "owner_id": owner,
            "code_mode": "none"}
    if project:
        body["project_id"] = project
    if source:
        body["source_channel_id"] = source
    t = api(WS, "POST", "/api/tasks", token, body)
    db.execute("UPDATE tasks SET created_at = ?, updated_at = ? WHERE id = ?",
               (days_ago(created_days_ago), days_ago(created_days_ago / 2), t["id"]))
    db.commit()
    return t


t33 = task(vince, "Upgrade to React 19", "App on React 19, no deprecation warnings.", "done", iris_id, app_project, created_days_ago=14)
t34 = task(jonas, "Password reset emails land in spam", "DMARC aligned, resets reach inboxes.", "done", sable_id, app_project, created_days_ago=12)
t35 = task(vince, "Churn digest every Monday", "A Monday morning digest in #growth: churn, saves, reasons.", "done", scout_id, created_days_ago=11)
t36 = task(maya, "Onboarding checklist experiment", "New studios see a 5-step checklist; measure trial→paid.", "done", maya_id, app_project, created_days_ago=10)
t37 = task(vince, "Rate-limit the public API", "Per-studio limits with clear 429s and docs.", "planned", iris_id, app_project, created_days_ago=6)
t38 = task(jonas, "Booking exports time out over 10k rows", "Exports finish under 30s for the largest studio.", "running", sable_id, app_project, created_days_ago=4)
t39 = task(maya, "Empty-state illustrations for schedule", "Schedule view has a warm empty state, not a blank grid.", "planned", maya_id, site_project, created_days_ago=4)
t40 = task(iris, "Stripe tax IDs on EU invoices", "EU studios get invoices with their VAT ID. Blocked: waiting on Stripe support ticket #48112.", "blocked", iris_id, app_project, created_days_ago=3)

# The hero conversation in #dev. The task card lands inline because the task
# is created from that channel, by Iris, mid-conversation.
stamps = {}  # message id -> created_at


def say(channel_id, token, body, minutes, kind=None, card=None):
    payload = {"body": body}
    if kind:
        payload["kind"] = kind
    if card:
        payload["card"] = card
    message = api(WS, "POST", f"/api/channels/{channel_id}/messages", token, payload)
    stamps[message["id"]] = minutes_ago(minutes)
    return message["id"]


def last_message(channel_id, minutes):
    page = api(WS, "GET", f"/api/channels/{channel_id}/messages?limit=100", vince)
    mid = page["messages"][-1]["id"]
    stamps[mid] = minutes_ago(minutes)
    return mid


def react(message_id, token, emoji):
    api(WS, "POST", f"/api/messages/{message_id}/reactions", token, {"emoji": emoji})


m1 = say(dev, jonas, "A studio in Berlin got double-booked the night DST ended — two confirmed bookings, same 09:00 slot. Their email is not friendly.", 178)
m2 = say(dev, vince, "Recurring slots are stored in local time, that's the bug. @iris take this one? Repro first, then fix.", 176)

t41 = task(iris, "Fix DST double-booking in recurring schedules",
           "Recurring bookings survive DST transitions in every timezone. Property test across the IANA db.",
           "review", iris_id, app_project, source=dev, created_days_ago=0)
last_message(dev, 172)  # the task card Iris just dropped in the conversation

say(dev, iris, "Reproduced with a Europe/Berlin fixture — the recurrence expander compares naive local times, so the repeated hour collides.", 169, kind="status")
say(dev, iris, "Root cause: `expandRecurring()` detects conflicts *before* converting to UTC. Moving detection to UTC instants and adding a property test that sweeps every IANA timezone. PR in ~20 minutes.", 156)
m_pr = say(dev, iris, "PR is up — 14 files, property test included. One studio needs a data fix; the migration ships with the PR.", 134,
           card={"type": "pull_request", "url": "https://github.com/meridianhq/meridian/pull/218", "task_id": t41["id"]})
api(WS, "PATCH", f"/api/tasks/{t41['id']}", iris, {"pr_url": "https://github.com/meridianhq/meridian/pull/218"})
m_maya = say(dev, maya, "While you're in there — could we warn studios with recurring classes the week before a DST shift? We got six tickets last spring.", 105)
react(m_maya, jonas, "👍")
react(m_maya, vince, "💡")
react(m_pr, vince, "🚀")

t42 = task(iris, "Warn studios before DST shifts", "Studios with recurring classes get a heads-up the week before a transition.", "planned", iris_id, app_project, created_days_ago=0)
t43 = task(vince, "Annual billing", "Studios can pay yearly; two months free.", "planned", vince_id, app_project, created_days_ago=2)
t44 = task(scout, "Class waitlists", "Full classes take a waitlist; spots offer themselves in order.", "planned", vince_id, app_project, created_days_ago=1)
t45 = task(sable, "Import bookings from Mindbody CSV", "A studio's Mindbody export lands as bookings, members, and passes.", "running", sable_id, app_project, created_days_ago=1)

# --- other rooms ------------------------------------------------------------

say(general, vince, "Welcome @quill — fourth agent on the team. Quill turns merged PRs into changelog entries and keeps the docs honest.", 60 * 26)
m_g = say(general, maya, "Four agents, three humans. Officially outnumbered 🎉", 60 * 25.8)
react(m_g, vince, "🎉")
react(m_g, jonas, "🤖")

say(support, scout, "Overnight: 7 tickets. Four are the DST double-booking (linked MER-41), two password resets, one asking for class waitlists — filed MER-44 and drafted replies for all seven. Two drafts need a human eye before they go out.", 60 * 4)
say(support, vince, "Drafts approved. Nice catch on the waitlist demand.", 60 * 3.5)
say(support, scout, "Sent. Waitlist asks this month: 9 — added the count to MER-44.", 60 * 3.4, kind="status")

say(deploys, sable, "meridian 2026.31.2 → production. 11 minutes, zero regressions, error rate flat.", 60 * 22, kind="status")
say(deploys, sable, "Nightly backup verified: restore drill passed in 4m12s.", 60 * 9, kind="status")
m_d = say(deploys, sable, "Heads up: Stripe webhook p95 crept to 900ms after 2026.31.2. Watching it — I roll back if it crosses 2s.", 60 * 2)
react(m_d, vince, "👀")

weeks = [("2026-06-16", 352), ("2026-06-23", 361), ("2026-06-30", 365), ("2026-07-07", 374),
         ("2026-07-14", 381), ("2026-07-21", 392), ("2026-07-28", 403), ("2026-08-04", 412)]
say(growth, scout,
    "Monday digest: 412 active studios, +9 WoW. Churn 1.9% (down from 2.4%). Trial→paid at 31% since the onboarding checklist — was 27%.",
    60 * 5,
    card={"type": "chart",
          "spec": {"data": {"values": [{"week": w, "studios": n} for w, n in weeks]},
                   "chart_spec": {"chartType": "Line Chart", "encodings": {"x": "week", "y": "studios"}}},
          "caption": "Active studios, last 8 weeks"})
say(growth, vince, "Checklist experiment is working. Roll it to 100%.", 60 * 4.6)

say(design, maya, "New empty state for the schedule view — draft is in Figma. Copy suggestions welcome.", 60 * 28)
say(design, quill, "Two options drafted on MER-39; the second matches the voice of the rest of onboarding.", 60 * 27)

say(bugs, jonas, "Exports time out for studios with more than 10k bookings. Filed MER-38 for @sable to profile the query.", 60 * 50)
say(bugs, sable, "Profiled: missing composite index on (studio_id, starts_at). Fix on MER-38, deploying behind a flag.", 60 * 47, kind="status")

say(product, vince, "Q3 theme is retention: waitlists (MER-44), annual billing (MER-43), onboarding checklist v2.", 60 * 30)
say(product, jonas, "@vince annual billing needs a pricing decision before Iris can start MER-43.", 42)

# --- live runs --------------------------------------------------------------
# Two runs the board and the chat can point at: Iris mid-task, Sable importing.

iris_run = "0198a001-0000-7000-8000-00000000a001"
sable_run = "0198a001-0000-7000-8000-00000000a002"
db.execute(
    "INSERT INTO runs (id, agent_id, status, trigger, channel_id, task_id, project_id, runtime, prompt, headline, depth, created_at, started_at) VALUES (?,?,?,?,?,?,?,?,?,?,0,?,?)",
    (iris_run, iris_id, "running", json.dumps({"type": "mention", "message_id": m2}), dev,
     t41["id"], app_project, "codex", "Fix the DST double-booking bug.",
     "Sweeping the property test across timezones", minutes_ago(170), minutes_ago(170)),
)
db.execute(
    "INSERT INTO runs (id, agent_id, status, trigger, channel_id, task_id, project_id, runtime, prompt, headline, depth, created_at, started_at) VALUES (?,?,?,?,?,?,?,?,?,?,0,?,?)",
    (sable_run, sable_id, "running", json.dumps({"type": "task_assignment", "task_id": t45["id"]}),
     t45["discussion_channel_id"], t45["id"], app_project, "pi",
     "Import the Mindbody CSV export.", "Importing 18,400 bookings from Mindbody CSV",
     minutes_ago(50), minutes_ago(50)),
)
db.execute("UPDATE tasks SET current_run_id = ? WHERE id = ?", (iris_run, t41["id"]))
db.execute("UPDATE tasks SET current_run_id = ? WHERE id = ?", (sable_run, t45["id"]))
db.commit()

# Iris hits a real product decision and asks instead of guessing. The card
# lands in #dev and the run visibly waits.
question = api(WS, "POST", "/api/questions", iris, {
    "run_id": iris_run,
    "headline": "DST warning: where should it surface?",
    "items": [{
        "id": "q1",
        "header": "DST warning",
        "question": "Maya's follow-up — where should the pre-DST warning reach studios?",
        "options": [
            {"label": "In-app banner", "description": "Cheapest. Only helps studios that log in that week."},
            {"label": "Email", "description": "Reaches everyone. Needs a new template and an unsubscribe path."},
            {"label": "Both", "description": "Banner plus email, one release."},
        ],
        "allow_free_text": True,
        "multi_select": False,
    }],
})
stamps[api(WS, "GET", f"/api/questions/{question['id']}", vince)["message_id"]] = minutes_ago(8)

# --- automations ------------------------------------------------------------

api(WS, "POST", "/api/automations", vince, {
    "name": "Monday churn digest",
    "description": "Start the week knowing who left and why.",
    "trigger": {"type": "cron", "expression": "0 9 * * 1"},
    "agent_id": scout_id,
    "action": "post_in_chat",
    "instructions": "Compare active studios and churn to last week. Post the chart and one paragraph — what moved and why.",
    "report_channel_id": growth,
})
api(WS, "POST", "/api/automations", vince, {
    "name": "PR feedback",
    "description": "Review comments come back to the agent that wrote the PR.",
    "trigger": {"type": "pull_request", "on_review_comment": True, "on_checks_failed": True},
    "agent_id": iris_id,
    "action": "continue_task",
    "instructions": "Address review comments and failing checks, push, and summarize what changed.",
})
api(WS, "POST", "/api/automations", vince, {
    "name": "Release notes",
    "description": "Shipped work explains itself.",
    "trigger": {"type": "task_status", "status": "done"},
    "agent_id": quill_id,
    "action": "post_in_chat",
    "instructions": "When a task lands with a merged PR, draft a changelog entry. Plain words, user's point of view.",
    "report_channel_id": general,
})
api(WS, "POST", "/api/automations", vince, {
    "name": "Deploy watchdog",
    "description": "Sable checks the dashboards so nobody else has to.",
    "trigger": {"type": "schedule", "every_seconds": 21600},
    "agent_id": sable_id,
    "action": "post_in_chat",
    "instructions": "Check error rates and latency since the last deploy. Post only if something moved.",
    "report_channel_id": deploys,
})

# Schedule-style automations fire once on creation; a demo does not want the
# half-finished run or its card.
db.execute("DELETE FROM messages WHERE kind = 'card' AND body = '' AND run_id IN (SELECT id FROM runs WHERE automation_id IS NOT NULL)")
db.execute("UPDATE runs SET status = 'cancelled', ended_at = ? WHERE automation_id IS NOT NULL", (NOW,))
db.execute("DELETE FROM inbox WHERE run_id IN (SELECT id FROM runs WHERE automation_id IS NOT NULL)")
db.execute("DELETE FROM messages WHERE body LIKE '%complete this run%'")
db.commit()

# --- switch the agents on ---------------------------------------------------

for agent_id, participation, channels_on in [
    (iris_id, "mention", {dev: "ambient"}),
    (scout_id, "mention", {support: "ambient"}),
    (sable_id, "mention", {deploys: "ambient"}),
    (quill_id, "mention", {}),
]:
    member = next(m for m in api(WS, "GET", "/api/members", vince) if m["id"] == agent_id)
    profile = member["agent"]
    profile["default_participation"] = participation
    profile["dm_enabled"] = True
    profile["channel_participation"] = channels_on
    api(WS, "PATCH", f"/api/agents/{agent_id}", vince, {"profile": profile})

# --- timestamps -------------------------------------------------------------

for mid, at in stamps.items():
    db.execute("UPDATE messages SET created_at = ? WHERE id = ?", (at, mid))
db.execute("""UPDATE channels SET last_message_at =
              COALESCE((SELECT MAX(created_at) FROM messages WHERE channel_id = channels.id), last_message_at)""")
db.execute("UPDATE members SET created_at = ?", (days_ago(21),))
db.execute("UPDATE inbox SET created_at = ? WHERE kind = 'question'", (minutes_ago(8),))
db.execute("UPDATE inbox SET created_at = ? WHERE kind = 'mention'", (minutes_ago(42),))
db.execute("UPDATE inbox SET created_at = ? WHERE kind NOT IN ('question', 'mention')", (days_ago(1.4),))
db.execute("UPDATE automations SET created_at = ?, last_run_at = ?", (days_ago(9), days_ago(0.2)))
db.commit()
db.close()

print(json.dumps({
    "workspace": WS,
    "relay_url": BASE,
    "vince": {"token": vince, "member_id": vince_id, "name": "Vince"},
    "channels": {"dev": dev, "growth": growth, "support": support, "deploys": deploys},
    "relay_pid": relay.pid,
}, indent=2))
