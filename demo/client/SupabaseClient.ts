import { createClient } from "@supabase/supabase-js";

const URL = "https://nixfbjgqturwbakhnwym.supabase.co";
const ANON_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5peGZiamdxdHVyd2Jha2hud3ltIiwicm9sZSI6ImFub24iLCJpYXQiOjE2NDc5NTk1ODksImV4cCI6MTk2MzUzNTU4OX0.YZMe4JJxd7SsB3__cLPg1ykGCG3krqc7sDKHQnlb4I4";

const supabaseClient = createClient(URL, ANON_KEY);
export { supabaseClient };
