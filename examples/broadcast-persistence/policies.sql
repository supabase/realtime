-- An AI coding harness. A human and an agent talk on the same channel, and the product decides
-- how much of that transcript is kept: the human's prompts only, or the whole conversation.
--
-- Sending and storing are two separate permissions, both answered by RLS against your own tables.
-- The agent can always talk. Whether its messages are kept is a policy decision.
--
-- What a policy cannot do is look at the message. The probe inserts a row carrying only topic and
-- extension, so the event and payload are not available to the predicate. A policy decides who may
-- store; the per-message `persist` flag decides which of their messages actually are.

create table if not exists public.session_members (
  topic text not null,
  user_id uuid not null,
  role text not null check (role in ('human', 'agent')),
  primary key (topic, user_id)
);

alter table public.session_members enable row level security;

insert into public.session_members (topic, user_id, role) values
  ('persisted:session-1', '11111111-1111-1111-1111-111111111111', 'human'),
  ('persisted:session-1', '22222222-2222-2222-2222-222222222222', 'agent'),
  ('persisted:bench',     '33333333-3333-3333-3333-333333333333', 'human')
on conflict (topic, user_id) do update set role = excluded.role;

-- The policies below read this table, so a member has to be able to see their own row.
drop policy if exists members_read_own on public.session_members;
create policy members_read_own on public.session_members for select to authenticated
  using ( user_id = auth.uid() );

drop policy if exists demo_read on realtime.messages;
drop policy if exists demo_send on realtime.messages;
drop policy if exists demo_persist on realtime.messages;
-- Presence is turned off for this tenant in `mise run setup`, so no presence policy is needed.
drop policy if exists demo_presence on realtime.messages;

-- Join and receive: anyone in the session.
create policy demo_read on realtime.messages for select to authenticated
  using (
    exists (
      select 1
        from public.session_members m
       where m.topic = realtime.topic()
         and m.user_id = auth.uid()
    )
  );

-- Send: human and agent both talk.
create policy demo_send on realtime.messages for insert to authenticated
  with check (
    realtime.messages.extension = 'broadcast'
    and exists (
      select 1
        from public.session_members m
       where m.topic = realtime.topic()
         and m.user_id = auth.uid()
    )
  );

-- Store: prompts only. Flip the checkbox on the page to keep the agent's replies as well.
create policy demo_persist on realtime.messages for insert to authenticated
  with check (
    realtime.messages.extension = 'persistence'
    and exists (
      select 1
        from public.session_members m
       where m.topic = realtime.topic()
         and m.user_id = auth.uid()
         and m.role in ('human')
    )
  );
