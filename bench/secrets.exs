alias RealtimeWeb.ChannelsAuthorization
alias Realtime.Helpers, as: H

jwt =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxvY2FsaG9zdCIsInJvbGUiOiJhbm9uIiwiaWF0IjoxNjU4NjAwNzkxLCJleHAiOjE5NzQxNzY3OTF9.Iki--9QilZ7vySEUJHj0a1T8BDHkR7rmdWStXImCZfk"

jwt_secret = "d3v_HtNXEpT+zfsyy1LE1WPGmNKLWRfw/rpjnVtCEEM2cSFV2s+kUh5OKX7TPYmG"

secret_key = "1234567890123456"
string_to_encrypt = "supabase_realtime"
string_to_decrypt = "A5mS7ggkPXm0FaKKoZtrsYNlZA3qZxFe9XA9w2YYqgU="

Benchee.run(%{
  "authorize_jwt" => fn ->
    {:ok, _} = ChannelsAuthorization.authorize_conn(jwt, jwt_secret)
  end,
  "encrypt_string" => fn ->
    H.encrypt!(string_to_encrypt, secret_key)
  end,
  "decrypt_string" => fn ->
    H.decrypt!(string_to_decrypt, secret_key)
  end
})
