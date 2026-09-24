import { readFileSync } from 'node:fs'
import { defineConfig } from 'vite'
import tailwindcss from '@tailwindcss/vite'
import jwt from 'jsonwebtoken'
import pg from 'pg'

const TENANT = process.env.TENANT ?? 'realtime-dev'
const JWT_SECRET = process.env.API_JWT_SECRET ?? 'dev'
const DATABASE_URL =
  process.env.DATABASE_URL ?? 'postgresql://supabase_admin:postgres@localhost:5433/postgres'

// Realtime resolves the tenant from the first dot-segment of the host, see
// Database.get_external_id/1, so plain localhost asks for a tenant called "localhost".
const REALTIME_URL = process.env.REALTIME_URL ?? `ws://${TENANT}.localhost:4000/socket`

// `realtime.messages.inserted_at` is `timestamp without time zone` holding UTC, but pg parses that
// type as local time. Without this the page shows every row shifted by your UTC offset.
pg.types.setTypeParser(pg.types.builtins.TIMESTAMP, (value) => new Date(`${value}Z`))

const pool = new pg.Pool({ connectionString: DATABASE_URL, max: 4 })

const send = (res, status, body) => {
  res.statusCode = status
  res.setHeader('content-type', 'application/json')
  res.end(JSON.stringify(body))
}

// A browser cannot sign a JWT or open a Postgres connection, so the dev server does both. In a real
// app the token comes from Supabase Auth and the reads go through PostgREST or your own backend.
function demoApi() {
  return {
    name: 'demo-api',
    configureServer(server) {
      server.middlewares.use(async (req, res, next) => {
        const url = new URL(req.url, 'http://localhost')

        if (url.pathname === '/api/config') {
          return send(res, 200, { tenant: TENANT, realtimeUrl: REALTIME_URL })
        }

        if (url.pathname === '/api/token') {
          const sub = url.searchParams.get('sub') ?? '11111111-1111-1111-1111-111111111111'
          const token = jwt.sign({ role: 'authenticated', sub }, JWT_SECRET, { expiresIn: '1h' })
          return send(res, 200, { token })
        }

        // Runs whatever SQL the policies panel sends. Fine for a demo against a local dev tenant,
        // never something to expose anywhere else.
        if (url.pathname === '/api/policies') {
          try {
            if (req.method === 'GET') {
              const { rows } = await pool.query(
                `select policyname, cmd, with_check, qual
                   from pg_policies
                  where schemaname = 'realtime' and tablename = 'messages'
                  order by policyname`
              )
              return send(res, 200, { rows })
            }

            if (req.method === 'DELETE') {
              await pool.query(`do $$
                declare p record;
                begin
                  for p in
                    select policyname from pg_policies
                     where schemaname = 'realtime'
                       and tablename = 'messages'
                       and policyname like 'demo\\_%'
                  loop
                    execute format('drop policy %I on realtime.messages', p.policyname);
                  end loop;
                end $$;`)
              return send(res, 200, { ok: true })
            }

            if (req.method === 'POST') {
              const body = await new Promise((resolve) => {
                let raw = ''
                req.on('data', (chunk) => (raw += chunk))
                req.on('end', () => resolve(raw))
              })

              const { sql } = JSON.parse(body || '{}')
              if (!sql?.trim()) return send(res, 400, { error: 'sql is required' })

              await pool.query(sql)
              return send(res, 200, { ok: true })
            }
          } catch (error) {
            return send(res, 500, { error: error.message })
          }
        }

        // Answers "would this policy let me?" the same way Realtime does: set the session config,
        // insert a probe row as `authenticated`, and roll it back. Insert success or 42501 is the
        // answer. The probe row carries only topic and extension, which is why no policy can
        // decide per message.
        if (url.pathname === '/api/check') {
          const topic = url.searchParams.get('topic')
          const sub = url.searchParams.get('sub') ?? '11111111-1111-1111-1111-111111111111'

          if (!topic) return send(res, 400, { error: 'topic is required' })

          const client = await pool.connect()

          try {
            await client.query('begin')
            await client.query(
              `select set_config('role', 'authenticated', true),
                      set_config('realtime.topic', $1, true),
                      set_config('request.jwt.claims', $2, true),
                      set_config('request.jwt.claim.sub', $3, true),
                      set_config('request.jwt.claim.role', 'authenticated', true)`,
              [topic, JSON.stringify({ sub, role: 'authenticated' }), sub]
            )
            await client.query('set local role authenticated')

            const result = {}

            for (const extension of ['broadcast', 'persistence']) {
              await client.query('savepoint probe')
              try {
                await client.query(
                  `insert into realtime.messages (id, topic, extension, private)
                   values (gen_random_uuid(), $1, $2, true)`,
                  [topic, extension]
                )
                result[extension] = 'allowed'
              } catch (error) {
                result[extension] = error.code === '42501' ? 'denied' : `error: ${error.message}`
              }
              await client.query('rollback to savepoint probe')
            }

            // Joining needs read, which Realtime probes by inserting rows and selecting them back.
            // Without it the join fails as "you do not have permissions to read from this topic".
            await client.query('savepoint probe')
            try {
              const id = '00000000-0000-4000-8000-00000000beef'
              await client.query(
                `insert into realtime.messages (id, topic, extension, private)
                 values ($1, $2, 'broadcast', true)`,
                [id, topic]
              )
              const { rowCount } = await client.query(
                'select 1 from realtime.messages where id = $1',
                [id]
              )
              result.read = rowCount === 1 ? 'allowed' : 'denied'
            } catch (error) {
              result.read = error.code === '42501' ? 'denied' : `error: ${error.message}`
            }
            await client.query('rollback to savepoint probe')

            await client.query('rollback')
            return send(res, 200, result)
          } catch (error) {
            await client.query('rollback').catch(() => {})
            return send(res, 500, { error: error.message })
          } finally {
            client.release()
          }
        }

        // Back to a known state: no rows, and the policies exactly as policies.sql defines them.
        if (url.pathname === '/api/restart' && req.method === 'POST') {
          try {
            await pool.query("delete from realtime.messages where topic like 'persisted:%'")
            await pool.query(readFileSync(new URL('./policies.sql', import.meta.url), 'utf8'))
            return send(res, 200, { ok: true })
          } catch (error) {
            return send(res, 500, { error: error.message })
          }
        }

        if (url.pathname === '/api/stored') {
          const topic = url.searchParams.get('topic')

          if (!topic) return send(res, 400, { error: 'topic is required' })

          try {
            if (req.method === 'DELETE') {
              const { rowCount } = await pool.query(
                'delete from realtime.messages where topic = $1',
                [topic]
              )
              return send(res, 200, { deleted: rowCount })
            }

            const { rows } = await pool.query(
              `select id, event, payload, inserted_at
                 from realtime.messages
                where topic = $1
                order by inserted_at desc`,
              [topic]
            )
            return send(res, 200, { rows })
          } catch (error) {
            return send(res, 500, { error: error.message })
          }
        }

        next()
      })
    },
  }
}

export default defineConfig({
  root: 'web',
  // `fs.allow` so the page can import policies.sql from the parent directory as its default text.
  server: { port: 5173, strictPort: true, fs: { allow: ['..'] } },
  plugins: [tailwindcss(), demoApi()],
})
