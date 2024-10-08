# Realtime E2E tests

Our E2E tests intend to test the usage of Realtime with Supabase and ensure we have no breaking changes. They require you to setup your project with some configurations to ensure they work as expected.

## Setup tests

### Project environment

- Create one user in the Authentication dashboard with the following information:

  - Email: test1@test.com
  - Password: test_test

- Run the following SQL

  ```sql
  CREATE TABLE public.pg_changes (
      id bigint GENERATED BY default AS IDENTITY PRIMARY KEY,
      value text NOT NULL DEFAULT gen_random_uuid()
  );

  CREATE TABLE public.dummy (
      id bigint GENERATED BY default AS IDENTITY PRIMARY KEY,
      value text NOT NULL DEFAULT gen_random_uuid()
  );

  CREATE TABLE public.authorization (
      id bigint GENERATED BY default AS IDENTITY PRIMARY KEY,
      value text NOT NULL DEFAULT gen_random_uuid()
  );

  ALTER TABLE public.pg_changes ENABLE ROW LEVEL SECURITY;
  ALTER TABLE public.authorization ENABLE ROW LEVEL SECURITY;
  ALTER PUBLICATION supabase_realtime ADD TABLE public.pg_changes;
  ALTER PUBLICATION supabase_realtime ADD TABLE public.dummy;

  CREATE POLICY "authenticated have full access to read"
  ON "realtime"."messages"
  AS PERMISSIVE FOR SELECT
  TO authenticated
  USING (true);

  CREATE POLICY "authenticated have full access to write"
  ON "realtime"."messages"
  AS PERMISSIVE FOR INSERT
  TO authenticated
  WITH CHECK (true);

  CREATE POLICY "allow authenticated users all access"
  ON "public"."pg_changes"
  AS PERMISSIVE FOR ALL
  TO authenticated
  USING ( true );
  ```

### Test enviroment

- Create .env based on .env.template with:
  - PROJECT_URL - URL for the project
  - PROJECT_ANON_TOKEN - Anon authentication token for the project

## Run tests

Run the following command
`deno test tests.ts --allow-read --allow-net --trace-leaks`
