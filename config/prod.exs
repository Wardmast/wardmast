import Config

config :wardmast_web, WardmastWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# Do not print debug messages in production
config :logger, level: :info

config :wardmast, :update_check, enabled: true

# SI1a (OD13): the daily upstream CLI bump + fetch (Wardmast.Worker.CliFetcher.Scheduler).
config :wardmast, :cli_fetcher, enabled: true

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
