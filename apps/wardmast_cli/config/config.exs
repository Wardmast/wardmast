import Config

# Share the umbrella root's config tree first (bd-2n4k1a). The :wardmast dep
# (and ash/spark/phoenix_live_view under it) read `compile_env` keys from it;
# a config tree without them makes Mix see different compile-time config here
# than in apps/wardmast and apps/wardmast_web, and recompile ash (607 files)
# and friends every time a run alternates between the apps, which blew the
# pre-push `tests` step's budget. The overrides below win over the root's.
#
# WARNING: `mix escript.build` embeds this config tree in the shipped `ward`
# escript (release builds use MIX_ENV=prod), so everything in the root
# config/config.exs and config/prod.exs ends up in the CLI binary. Keep the
# root compile-time config free of secrets; put them in runtime.exs.
import_config "../../../config/config.exs"

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# stdout carries command output (`--json`); logs go to stderr.
config :logger, :default_handler, config: [type: :standard_error]

# Use Jason for JSON parsing (consumed by Req)
config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
