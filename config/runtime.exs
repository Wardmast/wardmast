import Config

config :wardmast_web, WardmastWeb.Endpoint, http: [port: Wardmast.Env.server_port()]

# Max concurrent `/api` requests before the server answers 503 + Retry-After
# (WardmastWeb.Plugs.ApiConcurrencyLimit, bd-66anxj). `0` disables the limit.
case Integer.parse(Wardmast.Env.get("WARDMAST_API_MAX_CONCURRENCY", "")) do
  {n, ""} when n >= 0 -> config :wardmast_web, :api_max_concurrency, n
  _ -> :ok
end

# `:9443` bridge listener (bd-5uhdrs): `WARDMAST_BRIDGE_TLS12_ONLY=true` pins it to
# TLS 1.2 (default off: TLS 1.3 with 1.2 fallback). `WARDMAST_BRIDGE_STREAM_LOG_LEVEL`
# (debug|info|notice|warning) sets the level of Bridge.Stream's peer-close/error logs.
if Wardmast.Env.get("WARDMAST_BRIDGE_TLS12_ONLY") in ["1", "true", "TRUE", "True"] do
  config :wardmast, :bridge_tls12_only, true
end

case Wardmast.Env.get("WARDMAST_BRIDGE_STREAM_LOG_LEVEL") do
  level when level in ["debug", "info", "notice", "warning"] ->
    config :wardmast, :bridge_stream_close_log_level, String.to_existing_atom(level)

  _ ->
    :ok
end

# The VM's role (docs/design/remote-workers.md §3). `WARDMAST_ROLE=agent` makes this
# release a node agent: it starts only `Wardmast.NodeAgent.Supervisor`, so none
# of the primary's runtime config below applies — no SECRET_KEY_BASE, no Repo,
# no Endpoint. Unset (or empty) leaves the application default, `:primary`, and
# an unrecognised value refuses to boot instead of quietly becoming a primary.
# `Wardmast.NodeAgent.role/0` reads this back at boot.
agent? =
  case Wardmast.Env.get("WARDMAST_ROLE") do
    role when role in [nil, ""] ->
      false

    "primary" ->
      config :wardmast, role: :primary
      false

    "agent" ->
      config :wardmast, role: :agent
      true

    other ->
      raise "WARDMAST_ROLE must be \"primary\" or \"agent\", got: #{inspect(other)}"
  end

# Single source of truth for the SQLite DB path. Applies to all environments
# (dev, prod) except test, which sets its own tmp path in config/test.exs.
#
# Default: <data home>/arbiter.sqlite3 (the canonical post-cutover location), the data
# home being `Wardmast.Env.data_home/0`: the one resolver the server and `arb` share.
# Until T7 (DB-copy cutover) completes, set DATABASE_PATH to point at the
# live database so the server never boots against an empty file.
if config_env() != :test and not agent? do
  database_path =
    System.get_env("DATABASE_PATH") ||
      Path.join(Wardmast.Env.data_home(), "arbiter.sqlite3")

  config :wardmast, Wardmast.Repo,
    database: database_path,
    journal_mode: :wal,
    cache_size: -64_000,
    temp_store: :memory,
    busy_timeout: 5000,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")
end

# `WARDMAST_WORKER_JAIL_UNMASK`: colon- or comma-separated absolute paths the worker
# jail re-exposes (Wardmast.Worker.Jail.Hide). `~` expands against HOME. Malformed
# entries are skipped with a warning; this must never stop boot. Settable here
# because `ERL_FLAGS=-wardmast worker_jail_unmask ...` is unparseable through systemd.
jail_home = System.get_env("HOME") || ""

jail_unmask =
  "WARDMAST_WORKER_JAIL_UNMASK"
  |> Wardmast.Env.get("")
  |> String.split([":", ","], trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> Enum.flat_map(fn entry ->
    expanded =
      case entry do
        "~" -> jail_home
        "~/" <> rest -> Path.join(jail_home, rest)
        other -> other
      end

    if expanded != "" and Path.type(expanded) == :absolute do
      [expanded]
    else
      IO.warn("WARDMAST_WORKER_JAIL_UNMASK: skipping #{inspect(entry)} (not an absolute path)")
      []
    end
  end)

config :wardmast, :worker_jail_unmask, jail_unmask

# The dashboard's auth model is "a loopback peer is trusted; there is no
# login" (see WardmastWeb.Loopback) — bind loopback-only by default (bd-1c4pg3).
# WARDMAST_BIND_ADDRESS overrides it explicitly; WardmastWeb.Application logs a
# WARNING at boot if the result isn't loopback. Shared by :dev and :prod; it lives
# here (not config/dev.exs) because `Wardmast.Env` is only callable at runtime.
bind_ip = fn ->
  case Wardmast.Env.get("WARDMAST_BIND_ADDRESS") do
    addr when addr in [nil, ""] ->
      {127, 0, 0, 1}

    addr ->
      case :inet.parse_address(String.to_charlist(addr)) do
        {:ok, parsed} -> parsed
        {:error, _} -> raise "WARDMAST_BIND_ADDRESS is not a valid IP address: #{inspect(addr)}"
      end
  end
end

# A boot-time secret given inline (`NAME`) or as a pointer (`NAME_REF`:
# `aws-sm:<id>[#json-key]`, `aws-ssm:<name>` or `file:<path>`, resolved by
# `Wardmast.SecretRefs.External`; the pointer wins). It only calls into the
# resolver when a pointer is set, so an inline-only install never depends on it,
# and an unresolvable pointer raises, failing the boot as a missing value does.
secret_or_ref = fn name ->
  case System.get_env(name <> "_REF") do
    ref when ref in [nil, ""] -> System.get_env(name)
    _ref -> Wardmast.SecretRefs.External.env_or_ref!(name)
  end
end

if config_env() == :prod and not agent? do
  secret_key_base =
    secret_or_ref.("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing (set SECRET_KEY_BASE, or SECRET_KEY_BASE_REF to a secret-manager pointer)."

  config :wardmast_web, WardmastWeb.Endpoint,
    http: [ip: bind_ip.()],
    secret_key_base: secret_key_base,
    server: true,
    url: [
      host: System.get_env("PHX_HOST") || "localhost",
      port: Wardmast.Env.server_port(),
      scheme: "http"
    ],
    check_origin: false

  config :wardmast, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
end

if config_env() == :dev and not agent? do
  secret_key_base =
    secret_or_ref.("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing (set SECRET_KEY_BASE, or SECRET_KEY_BASE_REF to a secret-manager pointer).

      Generate one with `mix phx.gen.secret` and add it to .wardmast.env:
        SECRET_KEY_BASE=<generated-value>
      """

  config :wardmast_web, WardmastWeb.Endpoint,
    http: [ip: bind_ip.()],
    secret_key_base: secret_key_base
end
