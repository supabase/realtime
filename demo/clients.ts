import { createClient } from '@supabase/supabase-js'
import { RealtimeClient } from '@supabase/realtime-js'

const SUPABASE_URL = 'https://nixfbjgqturwbakhnwym.supabase.co'
const SUPABASE_ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5peGZiamdxdHVyd2Jha2hud3ltIiwicm9sZSI6ImFub24iLCJpYXQiOjE2NDc5NTk1ODksImV4cCI6MTk2MzUzNTU4OX0.YZMe4JJxd7SsB3__cLPg1ykGCG3krqc7sDKHQnlb4I4'

const REALTIME_URL = 'wss://nixfbjgqturwbakhnwym.realtime.abc3.dev/socket'
const REALTIME_ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5peGZiamdxdHVyd2Jha2hud3ltIiwicm9sZSI6ImFub24iLCJpYXQiOjE2NDc5NTk1ODksImV4cCI6MTk2MzUzNTU4OX0.YZMe4JJxd7SsB3__cLPg1ykGCG3krqc7sDKHQnlb4I4'

const supabaseClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY)

const realtimeClient = new RealtimeClient(REALTIME_URL, {
  params: {
    apikey: REALTIME_ANON_KEY,
  },
})
realtimeClient.setAuth(REALTIME_ANON_KEY)

export { supabaseClient, realtimeClient }
