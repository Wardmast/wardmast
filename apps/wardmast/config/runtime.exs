import Config

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      Path.join(System.user_home!(), ".wardmast/arbiter.sqlite3")

  config :wardmast, Wardmast.Repo,
    database: database_path,
    journal_mode: :wal,
    cache_size: -64_000,
    temp_store: :memory,
    busy_timeout: 5000
end
