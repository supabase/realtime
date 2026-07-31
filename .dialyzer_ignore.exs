# https://github.com/elixir-ecto/postgrex/pull/784
[
  {"lib/extensions/postgres_cdc_rls/replications.ex", :call},
  {"lib/extensions/postgres_cdc_rls/replications.ex", :no_return},
  {"lib/extensions/postgres_cdc_rls/subscriptions.ex", :call},
  {"lib/extensions/postgres_cdc_rls/subscriptions.ex", :no_return},
  # params_to_log/1 is only reached from the error branches that the no_return
  # cascade above makes Dialyzer treat as dead, so it is wrongly flagged unused.
  {"lib/extensions/postgres_cdc_rls/subscriptions.ex", :unused_fun}
]
