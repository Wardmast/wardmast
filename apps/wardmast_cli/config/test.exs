import Config

config :logger, level: :warning

# The :wardmast app boots in this VM too (test-only dep). The root config
# (imported from config/config.exs) already sets these phase-10 kill switches;
# repeating them here is belt-and-braces so this VM's `Heartbeat` never writes
# to the host-global `/run/user/<uid>/arbiter/heartbeat` (bd-3qkbch, phase 10).
config :wardmast, :sessions_heartbeat, enabled: false
config :wardmast, :sessions_idle_reaper, enabled: false
config :wardmast, :sessions_orphan_reaper, enabled: false
