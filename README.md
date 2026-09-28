# Dubai Owner Outreach Agent

A Telegram-based outreach bot for Dubai real estate agents, built on **n8n** and **Supabase**. It loads property owners from an Excel file, sends a first message, handles replies with a cheap-first intent classifier plus an LLM agent, follows up automatically, and hands off to a human when a conversation needs one.

The agent persona ("Sasha") aims to get the owner to list their property and send documents (title deed, EID). Messages are sent in English or Arabic.

## How it works

```
Excel file ─► WF1 Intake ─► owners table
                               │
                     WF2 Outreach (scheduled, templates)
                               │  first message on Telegram
                               ▼
Owner replies ─► WF3 Reply Agent ─► regex ─► Groq fallback ─► Switch
                                                  ├─ refused ─► template (status: lost)
                                                  ├─ closing ─► template (state: doc_collection)
                                                  └─ other ───► AI agent + tools
                               │
                     WF4 Follow-ups (hourly, templates)
                               └─ 3 attempts, then status: stalled + email alert
```

**Design principle:** spend LLM tokens only where judgment is needed. Outreach, follow-ups, refusals and "ready to send documents" replies are templates. Only objections, soft interest and unclear messages reach the agent.

## Workflows

| Workflow | Trigger | What it does |
|---|---|---|
| WF1 File Intake & Owner Loader | n8n form upload | Parses an Excel file with fuzzy column matching, cleans phone numbers, inserts rows into `owners` |
| WF2 Outreach | Schedule | Picks top `new` owners by priority, builds an EN/AR template message with a market-data line, sends it on Telegram, creates the conversation |
| WF3 Reply Agent | Telegram trigger | Classifies the reply (regex, then Groq if unknown), routes to a template or the AI agent, sends the reply, updates state and logs |
| WF4 Follow-up Scheduler | Hourly | Follows up owners silent for 24 h, up to 3 times, then marks them `stalled` |

### Agent tool sub-workflows

| Tool | Purpose |
|---|---|
| `search_objections` | Looks up a scripted response from the objections playbook |
| `get_market_data` | Returns average sale price and rent for an area and bedroom count |
| `flag_for_human` | Emails the human agents and pauses the conversation (`human_review`) |
| `send_telegram`, `log_message`, `update_state` | Helper sub-workflows (not attached to the agent) |

## Stack

- **n8n** (self-hosted in Docker) for orchestration
- **Supabase** (Postgres, pgvector) for data: `owners`, `conversations`, `messages`, `objections`, `market_data`
- **Telegram Bot API** for messaging
- **Groq** (`llama-3.1-8b-instant`) for fallback intent classification
- **OpenAI** (`gpt-5-mini`) for the reply agent, with Postgres chat memory per conversation
- **Gmail** for human-review and stalled-owner alerts

## Repository contents

```
workflows/
  WF1 - File Intake & Owner Loader.json
  WF2 - Outreach (Template-based, no Claude).json
  WF3 - Reply Agent.json
  WF4 - Follow-up Scheduler (Template-based, no Claude).json
  Tool Sub-Workflow - *.json        # six tool sub-workflows
supabase/
  workflows.sql                     # schema, match_objections function, sample market data
  schema.png                        # Supabase schema diagram
```

## Setup

### 1. Database

Run `sql/workflows.sql` in the Supabase SQL editor, including the `ALTER TABLE` statements at the end. Load your objection records into `objections` and replace the sample `market_data` rows with real figures.

### 2. Run n8n locally with a Cloudflare quick tunnel

Telegram needs a public HTTPS webhook, so a local n8n needs a tunnel.

`docker-compose.yml`:

```yaml
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n
    container_name: n8n
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      - WEBHOOK_URL=${WEBHOOK_URL}
      - N8N_EDITOR_BASE_URL=http://localhost:5678
    volumes:
      - n8n_data:/home/node/.n8n

volumes:
  n8n_data:
    external: true
```

Every session:

1. `docker volume create n8n_data` (first time only)
2. `docker compose up -d`
3. In a second terminal: `cloudflared tunnel --url http://localhost:5678`, then copy the `https://<words>.trycloudflare.com` address it prints
4. Put it in `.env` as `WEBHOOK_URL=https://<words>.trycloudflare.com/`
5. `docker compose up -d` again to recreate the container with the new URL

The quick-tunnel URL changes every time `cloudflared` restarts, so repeat steps 3 to 5 after each restart. For production, use a named Cloudflare tunnel on your own domain.

### 3. Import and configure

1. Import the six tool sub-workflows first, then WF1 to WF4.
2. Create credentials in n8n: Supabase API, Postgres (use the Supabase session pooler), Telegram, Gmail OAuth2, OpenAI, and a Groq bearer token.
3. In WF3, re-select the sub-workflow in each of the three tool nodes, since imported workflow IDs change.
4. Replace the hardcoded alert email addresses.
5. Activate the workflows: sub-workflows, WF1, WF3, then WF2 and WF4.

### 4. Telegram

Create a bot with @BotFather. A bot can only message users who have started it, so each owner's `telegram_id` in the Excel file must be their numeric chat ID.

## Status

Work in progress. Known open items:

- Log `conversation_id` on agent and template replies, and log inbound owner messages
- Set `last_contact_at` in WF2 so WF4 can pick up owners
- Align the Groq `agent` label with the Switch node in WF3
- Fix `get_market_data` and `search_objections` queries to use their tool inputs

## Security

Never commit credentials, API keys, n8n data volume backups or `.env` files. Exported workflow JSON contains placeholder credential IDs only; check for hardcoded email addresses before publishing.

[Dubai_Owner_Outreach_Agent_n8n_Workflow_Guide.pdf](https://github.com/user-attachments/files/32734162/Dubai_Owner_Outreach_Agent_n8n_Workflow_Guide.pdf)
