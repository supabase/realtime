# Script to generate a JWT token for testing WebSocket connections
# Usage: DB_ENC_KEY=your_key mix run priv/repo/generate_test_jwt.exs [tenant_external_id]
#
# If DB_ENC_KEY is not set, the script will try to use the default dev key.
# Default matches Makefile seed command: DB_ENC_KEY="1234567890123456"
# You can also set it in your environment or pass it as an env var:
#   DB_ENC_KEY=1234567890123456 mix run priv/repo/generate_test_jwt.exs dev_tenant

alias Realtime.Api.Tenant
alias Realtime.Crypto
alias Realtime.Repo

# Set default encryption key for development if not provided
# Default matches Makefile seed command: DB_ENC_KEY="1234567890123456"
db_enc_key = System.get_env("DB_ENC_KEY") || "1234567890123456"
Application.put_env(:realtime, :db_enc_key, db_enc_key)

tenant_id = System.argv() |> List.first() || "dev_tenant"

tenant = Repo.get_by(Tenant, external_id: tenant_id)

if tenant do
  secret = Crypto.decrypt!(tenant.jwt_secret)
  
  # Generate JWT token
  signer = Joken.Signer.create("HS256", secret)
  claims = %{role: "authenticated", exp: System.system_time(:second) + 100_000}
  {:ok, claims} = Joken.generate_claims(%{}, claims)
  {:ok, jwt, _} = Joken.encode_and_sign(claims, signer)
  
  IO.puts("\n=== JWT Token for #{tenant_id} ===")
  IO.puts(jwt)
  IO.puts("\n=== WebSocket URL ===")
  IO.puts("ws://#{tenant_id}.localhost:4000/socket/websocket?vsn=2.0.0")
  IO.puts("\n=== Test with curl ===")
  IO.puts("curl -i -N \\")
  IO.puts("  -H 'Host: #{tenant_id}' \\")
  IO.puts("  -H 'x-api-key: #{jwt}' \\")
  IO.puts("  -H 'Connection: Upgrade' \\")
  IO.puts("  -H 'Upgrade: websocket' \\")
  IO.puts("  -H 'Sec-WebSocket-Version: 13' \\")
  IO.puts("  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \\")
  IO.puts("  http://localhost:4000/socket/websocket")
  IO.puts("\n=== Or use browser console ===")
  IO.puts("const ws = new WebSocket('ws://#{tenant_id}.localhost:4000/socket/websocket?vsn=2.0.0', ['#{jwt}']);")
  IO.puts("ws.onopen = () => console.log('✅ WebSocket connected');")
  IO.puts("ws.onerror = (e) => console.log('❌ WebSocket error:', e);")
else
  IO.puts("❌ Tenant '#{tenant_id}' not found!")
  IO.puts("Available tenants:")
  Repo.all(Tenant) |> Enum.each(fn t -> IO.puts("  - #{t.external_id}") end)
end

