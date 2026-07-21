SELECT EXISTS (
  SELECT 1 FROM pg_policies
  WHERE schemaname = 'realtime' AND tablename = 'messages_opt3'
  AND policyname = 'allow_news'
) AS enabled;
