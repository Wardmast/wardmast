import Config

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# stdout carries command output (`--json`); logs go to stderr.
config :logger, :default_handler, config: [type: :standard_error]

# Use Jason for JSON parsing (consumed by Req)
config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
