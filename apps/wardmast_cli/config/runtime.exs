import Config

# The CLI reads WARDMAST_HOST / WARDMAST_WORKSPACE (with ARB_HOST / ARB_WORKSPACE
# fallback via Wardmast.Env) and ARB_TOKEN at call-site (see WardmastCli.Client
# and WardmastCli.Workspace). There is no server-side config (SECRET_KEY_BASE,
# DATABASE_PATH, endpoint bind config) here — those belong to the wardmast_web
# release, not the escript.
