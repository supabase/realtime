-- Two separate permissions on the same topic.
--
-- The broadcast policy decides who may send. The persistence policy decides whose messages may be
-- stored. A sender can pass the first and fail the second, in which case the message is delivered
-- and not kept.
--
-- Neither policy can see the message itself. The probe inserts a row carrying only topic and
-- extension, so the event and payload are not available to the predicate. That is why asking to
-- persist is a per-message flag and not something a policy can express.

drop policy if exists demo_read on realtime.messages;
drop policy if exists demo_send on realtime.messages;
drop policy if exists demo_persist on realtime.messages;
drop policy if exists demo_presence on realtime.messages;

-- Read: needed to receive broadcasts and to replay them on join.
create policy demo_read on realtime.messages for select to authenticated
  using (realtime.topic() like 'persisted:%');

-- Presence, which this demo does not use but still has to allow.
--
-- Presence is on unless the tenant turns it off, see presence_enabled?/2, and the read probe
-- inserts one row per enabled extension in a single statement. One denied row fails the whole
-- insert, so without this policy the join dies before the demo starts. The SELECT policy above
-- still decides whether presence is readable.
create policy demo_presence on realtime.messages for insert to authenticated
  with check (
    realtime.messages.extension = 'presence'
    and realtime.topic() like 'persisted:%'
  );

-- Send: who may broadcast on this topic.
create policy demo_send on realtime.messages for insert to authenticated
  with check (
    realtime.messages.extension = 'broadcast'
    and realtime.topic() like 'persisted:%'
  );

-- Store: whose broadcasts may be written to realtime.messages.
create policy demo_persist on realtime.messages for insert to authenticated
  with check (
    realtime.messages.extension = 'persistence'
    and realtime.topic() like 'persisted:%'
  );
