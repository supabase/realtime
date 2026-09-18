// The one decision this demo is about: how much of a coding session is kept.
//
// `policyFor(keepAgent)` returns a complete, runnable policy set. Only the roles allowed to store
// change; read and send are always included so running it never leaves a channel you
// cannot join. Rejoin afterwards, since a channel caches its policy answer.

const membership = `exists (
      select 1
        from public.session_members m
       where m.topic = realtime.topic()
         and m.user_id = auth.uid()
    )`

const base = `
-- Unchanged: human and agent can both join and talk.
drop policy if exists demo_presence on realtime.messages;
drop policy if exists demo_read on realtime.messages;
create policy demo_read on realtime.messages for select to authenticated
  using ( ${membership} );


drop policy if exists demo_send on realtime.messages;
create policy demo_send on realtime.messages for insert to authenticated
  with check ( realtime.messages.extension = 'broadcast' and ${membership} );
`

export function policyFor(keepAgent) {
  const roles = keepAgent ? `'human', 'agent'` : `'human'`

  return `-- Keep ${keepAgent ? 'the whole transcript' : 'the human prompts only'}.
drop policy if exists demo_persist on realtime.messages;
create policy demo_persist on realtime.messages for insert to authenticated
  with check (
    realtime.messages.extension = 'persistence'
    and exists (
      select 1
        from public.session_members m
       where m.topic = realtime.topic()
         and m.user_id = auth.uid()
         and m.role in (${roles})
    )
  );
${base}`
}

// What each identity should get for a given checkbox state. The page checks the real answer
// against this, so a wrong claim here shows up rather than going unnoticed.
export const expected = {
  false: { human: 'allowed', agent: 'denied' },
  true: { human: 'allowed', agent: 'allowed' },
}

export const identities = [
  { name: 'You', sub: '11111111-1111-1111-1111-111111111111', key: 'human' },
  { name: 'Agent', sub: '22222222-2222-2222-2222-222222222222', key: 'agent' },
]
