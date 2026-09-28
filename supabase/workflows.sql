-- ============================================================
-- Dubai Real Estate AI Agent — Supabase Schema v1 (simple)
-- Run this entire file in Supabase SQL editor
-- ============================================================

-- Enable pgvector (run once per project)
create extension if not exists vector;


-- ============================================================
-- TABLE 1: owners
-- Populated by WF1 from agent-uploaded files
-- ============================================================
create table if not exists owners (
  id                uuid primary key default gen_random_uuid(),
  owner_name        text not null,
  phone_wa          text,                        -- WhatsApp number, intl format e.g. 971501234567
  email             text,
  sms_number        text,
  language          text default 'en',           -- 'en' or 'ar'
  property_ref      text,                        -- building + unit e.g. "Stonehenge JVC 1BR"
  area              text,                        -- JVC / Arjan / JLT / Downtown / Business Bay
  beds              int,
  transaction_type  text,                        -- Sale / Rental
  asking_price      numeric,
  priority_score    int default 50,              -- 0-100, higher = contact first
  status            text default 'new',          -- new | waiting_reply | active | won | lost | stalled
  follow_up_count   int default 0,
  last_contact_at   timestamptz,
  source_file       text,                        -- original filename for traceability
  created_at        timestamptz default now(),
  updated_at        timestamptz default now()
);

-- Index for the WF4 follow-up scheduler query
create index if not exists idx_owners_status on owners(status);
create index if not exists idx_owners_last_contact on owners(last_contact_at);


-- ============================================================
-- TABLE 2: conversations
-- One row per owner per channel thread
-- ============================================================
create table if not exists conversations (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid references owners(id) on delete cascade,
  channel          text not null,               -- whatsapp | email | sms
  thread_id        text,                        -- WA phone / email thread / SMS number
  state            text default 'outreach',     -- outreach | qualification | objection_raised | listing_pitch | doc_collection | viewing_arranged | negotiation | waiting_reply | won | lost | stalled
  outcome          text,                        -- won | lost | stalled | null while active
  variant_id       text,                        -- A/B test variant tag
  is_archived      boolean default false,
  last_message_at  timestamptz,
  created_at       timestamptz default now()
);

create index if not exists idx_convos_owner on conversations(owner_id);
create index if not exists idx_convos_state on conversations(state);
create index if not exists idx_convos_channel_thread on conversations(channel, thread_id);


-- ============================================================
-- TABLE 3: messages
-- Every single message, both directions
-- ============================================================
create table if not exists messages (
  id                   uuid primary key default gen_random_uuid(),
  conversation_id      uuid references conversations(id) on delete cascade,
  sender               text not null,            -- 'agent' | 'owner'
  content              text not null,
  conversation_stage   text,                     -- state at time of message
  intent_detected      text,                     -- from Switch node / Claude
  turn_number          int,
  sent_at              timestamptz default now()
);

create index if not exists idx_messages_convo on messages(conversation_id);
create index if not exists idx_messages_sent_at on messages(sent_at);


-- ============================================================
-- TABLE 4: objections
-- Loaded from your 37-record docx_cleaned.json
-- ============================================================
create table if not exists objections (
  id                uuid primary key default gen_random_uuid(),
  source_id         text unique,                 -- L-01, P-01 etc.
  title             text,
  objection_text    text,
  real_quote        text,
  category          text,                        -- listing_refusal | price_commission | trust_credibility etc.
  ai_script         text,
  followup_question text,
  success_signal    text,
  tags              text[],
  areas             text[],
  owner_type        text,
  channel           text,
  embedding         vector(1024),               -- Voyage AI voyage-3-lite
  created_at        timestamptz default now()
);

create index if not exists idx_objections_category on objections(category);


-- ============================================================
-- TABLE 5: market_data
-- Manually refreshed from Bayut, used in 1st message + replies
-- ============================================================
create table if not exists market_data (
  id              uuid primary key default gen_random_uuid(),
  area            text not null,                -- JVC | Arjan | JLT | Downtown | Business Bay
  property_type   text default 'Apartment',
  beds            int,                          -- 0=studio, 1, 2, 3...
  avg_sale_price  numeric,                      -- AED
  avg_rent_annual numeric,                      -- AED
  avg_price_sqft  numeric,                      -- AED/sqft
  data_date       date,                         -- when Bayut data was pulled
  source          text default 'Bayut',
  updated_at      timestamptz default now()
);

create index if not exists idx_market_area_beds on market_data(area, beds);


-- ============================================================
-- FUNCTION: match_objections
-- Semantic search — called from WF3 reply handler
-- ============================================================
create or replace function match_objections(
  query_embedding vector(1024),
  match_threshold float default 0.75,
  match_count     int default 3
)
returns table (
  id              uuid,
  source_id       text,
  title           text,
  category        text,
  ai_script       text,
  followup_question text,
  success_signal  text,
  similarity      float
)
language sql stable
as $$
  select
    o.id,
    o.source_id,
    o.title,
    o.category,
    o.ai_script,
    o.followup_question,
    o.success_signal,
    1 - (o.embedding <=> query_embedding) as similarity
  from objections o
  where 1 - (o.embedding <=> query_embedding) > match_threshold
  order by o.embedding <=> query_embedding
  limit match_count;
$$;


-- ============================================================
-- FUNCTION: updated_at trigger (keep updated_at fresh on owners)
-- ============================================================
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger owners_updated_at
  before update on owners
  for each row execute function set_updated_at();


-- ============================================================
-- SAMPLE market_data rows (replace with real Bayut data)
-- ============================================================
insert into market_data (area, beds, avg_sale_price, avg_rent_annual, avg_price_sqft, data_date) values
  ('JVC',          0, 500000,   38000,  1100, current_date),
  ('JVC',          1, 780000,   55000,  1150, current_date),
  ('JVC',          2, 1150000,  75000,  1200, current_date),
  ('Arjan',        0, 480000,   36000,  1050, current_date),
  ('Arjan',        1, 750000,   52000,  1100, current_date),
  ('JLT',          1, 950000,   70000,  1300, current_date),
  ('JLT',          2, 1450000,  95000,  1350, current_date),
  ('Downtown',     1, 1800000,  110000, 2200, current_date),
  ('Downtown',     2, 2800000,  150000, 2300, current_date),
  ('Business Bay', 1, 1200000,  80000,  1600, current_date),
  ('Business Bay', 2, 1900000,  110000, 1650, current_date)
on conflict do nothing;

-- Run this too
ALTER TABLE owners ADD COLUMN IF NOT EXISTS status_note text;
-- The human_review status is already handled by the status field

ALTER TABLE owners ADD COLUMN IF NOT EXISTS phone_country_code varchar;
ALTER TABLE owners ADD column if NOT exists actual_size text;
ALTER TABLE owners ADD column if NOT EXISTS building text;
ALTER TABLE owners ADD column if NOT EXISTS completion_status text;
ALTER TABLE owners ADD column if NOT EXISTS project text;
ALTER TABLE owners ADD column if NOT EXISTS property_type text;
ALTER TABLE owners ADD column if NOT EXISTS trancs text;
ALTER TABLE owners RENAME COLUMN transaction_type TO transaction_amount;
ALTER TABLE owners ADD COLUMN IF NOT EXISTS unit_number text;

SELECT * FROM owners WHERE phone_wa = '973563235116';

ALTER TABLE owners ADD COLUMN if NOT exists telegram_id text;
ALTER TABLE owners ADD COLUMN IF NOT EXISTS tele_chat_id text UNIQUE;

SELECT * FROM owners

-- Also check if any messages exist with null conversation_id
SELECT * FROM messages WHERE conversation_id IS NULL ORDER BY sent_at DESC LIMIT 5;