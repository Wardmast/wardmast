#!/usr/bin/env bash
#
# One-shot migration of an existing pre-rename Arbiter install to the Wardmast
# footprint (bd-4jzgwa). Run it ONCE on each host that has a `~/.arbiter` install
# (the operator's laptop, the box that runs the primary):
#
#   systemctl --user stop arbiter.service      # the script refuses while it runs
#   scripts/migrate-from-arbiter.sh [--dry-run]
#   systemctl --user start wardmast.service
#
# What it does, in order. Every step checks its own precondition, so a re-run
# (or a run that was interrupted half way) finishes the job and a finished
# migration is a no-op:
#
#   1. Refuses while the server is running (arbiter.service / wardmast.service
#      active, or a live pid in the data home's pid file). Nothing is touched.
#   2. Moves ~/.arbiter to ~/.wardmast (one same-filesystem rename: DB, releases,
#      snapshots, logs) and leaves ~/.arbiter as a symlink to it, so anything
#      still holding the old path (a shell profile, a stale drop-in, a tool
#      that cached it) keeps working. Absolute symlinks inside the data home
#      (`current`, ...) are repointed at the new location.
#   3. Renames <data home>/arbiter.env to wardmast.env and rewrites it: the
#      operator-facing ARB_* / ARBITER_* keys become WARDMAST_* (including
#      ARB_PRIMARY_CHECKOUT -> WARDMAST_PRIMARY_CHECKOUT), and any
#      <home>/.arbiter path inside a value becomes <home>/.wardmast. Keys the
#      server exports to workers (ARB_TOKEN, ARB_NODE_*, ARBITER_MCP_TOKEN, ...)
#      are left alone. The original is kept as wardmast.env.pre-migrate (0600).
#   4. Renames log/arbiter.log* to wardmast.log* and fixes the logrotate config.
#   5. Installs wardmast.service (plus its drop-ins and the logrotate units),
#      transformed from the unit you already have, so local tuning survives;
#      disables arbiter.service and parks the old files as *.pre-wardmast, out
#      of systemd's search path. It enables the new unit but does NOT start it.
#   6. Moves ~/.config/arbiter/home (the recorded checkout) to ~/.config/wardmast/,
#      and renames the checkout's own .arbiter.env to .wardmast.env.
#
# The database file keeps its name (arbiter.sqlite3) inside the new directory.
#
# Cluster installs are a separate, manual step: see `--helm-notes`.
#
# Exit codes: 0 migrated / nothing to do, 1 refused or failed, 2 bad usage.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/migrate-from-arbiter.sh [--dry-run] [--helm-notes] [--help]

Migrate an existing Arbiter install (~/.arbiter, arbiter.service) to Wardmast
(~/.wardmast, wardmast.service). Idempotent; refuses while the server is running.

  --dry-run     show what would change, change nothing
  --helm-notes  print the matching `helm upgrade` steps for a cluster install
  --help        this text
EOF
}

# Operator-facing variables the server reads under their WARDMAST_ name
# (Wardmast.Env). ARB_<NAME> / ARBITER_<NAME> for these are rewritten to
# WARDMAST_<NAME>. Deliberately absent: the wire-contract variables the server
# exports to workers and the CLI (TOKEN, HOST, WORKSPACE, NODE_*, ...).
REWRITE_KEYS="ACCOUNTS_ROOT API_MAX_CONCURRENCY BACKUP_DEST BACKUP_SRC BIND_ADDRESS BRIDGE_STREAM_LOG_LEVEL BRIDGE_TLS12_ONLY BUILD_RELEASE_REPO CLI_FETCHER CLOAK_KEY CLOAK_KEY_GENERATION CLOAK_KEY_OLD COORDINATOR_SESSION_DIRS DASHBOARD_TAILSCALE_LOGINS DASHBOARD_TRUST_LOOPBACK DATA_HOME GITHUB_API IMAGE_ROOT INSTALL_BIN MEMORY_ROOT OUTPUT_LOG_ROOT PODMAN_PROBE_IMAGE PRIMARY_CHECKOUT RELEASE_REPO SCRATCH_ROOT SECRET_CACHE_TTL SESSIONS_ROOT SOCKET_ROOT UPDATE_CHECK UPDATE_CHECK_INTERVAL_HOURS WORKER_JAIL_UNMASK WORKER_MEMORY_MAX WORKER_TMP_ROOT WORKTREE_ROOT"

helm_notes() {
  cat <<'EOF'
Cluster install (helm) — the matching upgrade for an existing `arbiter-node` release
=====================================================================================

What changed in the chart: the chart is now `wardmast-node`, the controller image is
ghcr.io/<owner>/wardmast-controller, every object name is `wardmast-*` (the
Deployment/ServiceAccount/Role `wardmast-controller`, the worker ServiceAccount
`wardmast-worker`, ConfigMaps `wardmast-controller-config` / `wardmast-ca`, Secret
`wardmast-node-credential`, ...), pod labels are `wardmast.dev/*`, and the default
namespace is `wardmast-workers`. Object names are fixed (the controller hard-codes
them), so a plain `helm upgrade` would delete the old objects and create new ones —
including the Secret that holds this node's credential. Do the steps in this order
and do not skip the credential copy.

Placeholders: NS is your existing namespace (default was `arbiter-workers`), REL your
helm release name (`helm list -n NS`), VERSION a release containing this change.

 1. Let in-flight cluster runs finish (or accept losing them): worker pods carry the
    old `arbiter.dev/*` labels, which the new controller no longer adopts or sweeps.
    Afterwards remove stragglers:
        kubectl -n NS delete pods -l arbiter.dev/install

 2. Copy the node credential to its new name (the controller's Role is name-scoped):
        kubectl -n NS get secret arbiter-node-credential -o json \
          | jq '.metadata |= {name: "wardmast-node-credential"} | .metadata.namespace = "NS"' \
          | kubectl apply -f -
    Same for the CA Secret and the join/tailscale Secrets you created by hand
    (`arbiter-controller-ca` -> `wardmast-controller-ca`, `arbiter-join` -> `wardmast-join`,
    `arbiter-tailscale` -> `wardmast-tailscale`; or point values `join.existingSecret` /
    `reach.tailscale.authKeySecret` at the old names).

 3. The Deployment's selector label changed and selectors are immutable, so remove the
    old controller Deployment first (it is stateless; the credential lives in the Secret):
        kubectl -n NS delete deployment arbiter-controller

 4. Upgrade the release onto the renamed chart, keeping your namespace and values:
        helm upgrade REL oci://ghcr.io/<owner>/charts/wardmast-node --version VERSION \
          -n NS --reuse-values \
          --set image.repository=ghcr.io/<owner>/wardmast-controller
    (from a checkout: `helm upgrade REL ./charts/wardmast-node -n NS --reuse-values`).
    Keep -n NS: a Kubernetes namespace cannot be renamed, and the chart does not hard-code
    one, so an existing install may stay in `arbiter-workers`. Only a NEW install defaults
    to `wardmast-workers`.

 5. Verify, then delete what is left of the old names:
        kubectl -n NS rollout status deployment/wardmast-controller
        ward node show REL                       # status: connected / ready
        kubectl -n NS delete secret arbiter-node-credential arbiter-controller-ca --ignore-not-found
    The cluster-scoped guardrails (PriorityClass, RuntimeClass, ValidatingAdmissionPolicy
    + Binding) are renamed by the same upgrade; helm removes the old ones. Check
    `kubectl get priorityclass,runtimeclass,validatingadmissionpolicy | grep arbiter`
    is empty.

Not renamed on purpose: the tailscale ACL tag `tag:arbiter-node` (it lives in your tailnet
policy, not here — rename it there and in `reach.tailscale` values together, if you want
to), and the `arbiter.runtime-contract` label inside the worker base image.

If anything goes wrong before step 3, nothing has changed. After step 3, `helm rollback`
cannot restore the deleted Deployment; re-install the old chart version
(`helm upgrade REL oci://ghcr.io/<owner>/charts/arbiter-node --version <previous>`) and
restore the secret from the copy you took in step 2.
EOF
}

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --helm-notes)
      helm_notes
      exit 0
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "${HOME:-}" ]; then
  echo "error: HOME is not set" >&2
  exit 1
fi

OLD="$HOME/.arbiter"
NEW="$HOME/.wardmast"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
UNITS="$CONFIG_HOME/systemd/user"
CHANGED=0

say() { printf '%s\n' "$*"; }
note() { say "  $*"; CHANGED=1; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# --- sed: pure text rewrites shared by the env file, units and drop-ins ----------

# Escape a literal for a sed -E regex with `#` as the delimiter.
re_escape() { printf '%s' "$1" | sed -e 's/[][\.*^$#/+?(){}|]/\\&/g'; }
# ...and for the replacement side.
rep_escape() { printf '%s' "$1" | sed -e 's/[\\&#]/\\&/g'; }

HOME_RE="$(re_escape "$HOME")"
HOME_REP="$(rep_escape "$HOME")"
KEYS_ALT="$(printf '%s' "$REWRITE_KEYS" | tr ' ' '|')"

# stdin -> stdout. Paths, file names and unit names only; key renames are done
# separately for the env file (they need to know about already-present keys) and
# inline here for `Environment=` lines in units.
rewrite_text() {
  sed -E \
    -e "s#(${HOME_RE}|~|\\\$HOME|\\\$\\{HOME\\})/\\.arbiter(/|[^A-Za-z0-9_.-]|\$)#\\1/.wardmast\\2#g" \
    -e 's#(/\.wardmast/)arbiter\.env#\1wardmast.env#g' \
    -e 's#(/\.wardmast/log/)arbiter\.log#\1wardmast.log#g' \
    -e 's#/bin/arbiter( |$)#/bin/wardmast\1#g' \
    -e 's#arbiter-logrotate\.(service|timer)#wardmast-logrotate.\1#g' \
    -e 's#(^|[^A-Za-z0-9_.-])arbiter\.service#\1wardmast.service#g' \
    -e 's#^(Description=.*)Arbiter#\1Wardmast#' \
    -e "s#^(Environment=\"?)(ARB|ARBITER)_(${KEYS_ALT})(_REF)?=#\\1WARDMAST_\\3\\4=#"
}

# --- 1. refuse while the server is running ---------------------------------------

service_active() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user is-active --quiet "$1" 2>/dev/null
}

for unit in arbiter.service wardmast.service; do
  if service_active "$unit"; then
    die "$unit is active. Stop the server first (systemctl --user stop $unit), then re-run."
  fi
done

for dir in "$OLD" "$NEW"; do
  for pidfile in "$dir/arbiter.pid" "$dir/wardmast.pid"; do
    [ -f "$pidfile" ] || continue
    pid="$(tr -dc '0-9' <"$pidfile" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      # Guard against a recycled pid: only an Erlang VM counts as "the server".
      if [ ! -r "/proc/$pid/cmdline" ] || tr '\0' ' ' <"/proc/$pid/cmdline" | grep -qE 'beam|erlexec|wardmast|arbiter'; then
        die "$pidfile names a live server process (pid $pid). Stop it, then re-run."
      fi
    fi
  done
done

[ "$DRY_RUN" = 1 ] && say "dry run: nothing will be changed"

# --- 2. data home ----------------------------------------------------------------

move_data_home() {
  if [ -L "$OLD" ]; then
    case "$(readlink "$OLD")" in
      .wardmast | "$NEW" | "$NEW"/) return 0 ;;
      *) die "$OLD is a symlink to somewhere else ($(readlink "$OLD")); resolve it by hand." ;;
    esac
  elif [ -d "$OLD" ]; then
    if [ -e "$NEW" ]; then
      die "both $OLD and $NEW exist as real directories. Decide which one is the live data home, merge or move the other aside, then re-run."
    fi
    if [ "$DRY_RUN" = 1 ]; then
      note "would move $OLD -> $NEW and leave $OLD as a symlink"
    else
      mv "$OLD" "$NEW"
      ln -s .wardmast "$OLD"
      note "moved $OLD -> $NEW (compat symlink left at $OLD)"
    fi
  fi
}

# Absolute symlinks that still point into the old directory (`current`, ...).
repoint_links() {
  [ -d "$NEW" ] || return 0
  local link target
  for link in "$NEW"/* "$NEW"/releases/*; do
    [ -L "$link" ] || continue
    target="$(readlink "$link")"
    case "$target" in
      "$OLD"/*)
        if [ "$DRY_RUN" = 1 ]; then
          note "would repoint $link -> $NEW/${target#"$OLD"/}"
        else
          ln -sfn "$NEW/${target#"$OLD"/}" "$link"
          note "repointed $link -> $NEW/${target#"$OLD"/}"
        fi
        ;;
    esac
  done
}

# --- 3. env file -----------------------------------------------------------------

# Rewrite the env file at $1 in place (key renames + path rewrites), keeping the
# first-ever version as $1.pre-migrate. Idempotent.
rewrite_env_file() {
  local file="$1" tmp line prefix name ref rest
  tmp="$(mktemp "${file}.XXXXXX")"
  chmod 600 "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^([[:space:]]*(export[[:space:]]+)?)(ARB|ARBITER)_(${KEYS_ALT})(_REF)?=(.*)$ ]]; then
      prefix="${BASH_REMATCH[1]}"
      name="${BASH_REMATCH[4]}"
      ref="${BASH_REMATCH[5]}"
      rest="${BASH_REMATCH[6]}"
      # An explicit WARDMAST_ line wins (Wardmast.Env), so the legacy twin is dropped.
      if grep -Eq "^[[:space:]]*(export[[:space:]]+)?WARDMAST_${name}${ref}=" "$file"; then
        continue
      fi
      line="${prefix}WARDMAST_${name}${ref}=${rest}"
    fi
    printf '%s\n' "$line"
  done <"$file" | rewrite_text >"$tmp"

  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    rm -f "$tmp"
    note "would rewrite keys/paths in $file"
    return 0
  fi
  [ -e "$file.pre-migrate" ] || cp -p "$file" "$file.pre-migrate"
  cat "$tmp" >"$file" # keeps the inode and the 0600 mode
  rm -f "$tmp"
  note "rewrote keys/paths in $file (original: $file.pre-migrate)"
}

migrate_env_file() {
  [ -d "$NEW" ] || return 0
  if [ -f "$NEW/arbiter.env" ]; then
    if [ -e "$NEW/wardmast.env" ]; then
      die "both $NEW/arbiter.env and $NEW/wardmast.env exist; merge them by hand into wardmast.env and delete arbiter.env."
    fi
    if [ "$DRY_RUN" = 1 ]; then
      note "would rename $NEW/arbiter.env -> wardmast.env"
    else
      mv "$NEW/arbiter.env" "$NEW/wardmast.env"
      note "renamed arbiter.env -> wardmast.env"
    fi
  fi
  if [ -f "$NEW/wardmast.env" ]; then
    rewrite_env_file "$NEW/wardmast.env"
  fi
}

# --- 4. logs ---------------------------------------------------------------------

migrate_logs() {
  [ -d "$NEW/log" ] || return 0
  local f base
  for f in "$NEW"/log/arbiter.log "$NEW"/log/arbiter.log.*; do
    [ -e "$f" ] || continue
    base="wardmast.log${f##*/arbiter.log}"
    [ -e "$NEW/log/$base" ] && continue
    if [ "$DRY_RUN" = 1 ]; then
      note "would rename ${f##*/} -> $base"
    else
      mv "$f" "$NEW/log/$base"
      note "renamed log/${f##*/} -> log/$base"
    fi
  done
  if [ -f "$NEW/log/logrotate.conf" ]; then
    rewrite_in_place "$NEW/log/logrotate.conf"
  fi
}

# Generic in-place rewrite_text for a non-secret file; only touches it when the
# result differs.
rewrite_in_place() {
  local file="$1" tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  rewrite_text <"$file" >"$tmp"
  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
  elif [ "$DRY_RUN" = 1 ]; then
    rm -f "$tmp"
    note "would rewrite $file"
  else
    cat "$tmp" >"$file"
    rm -f "$tmp"
    note "rewrote $file"
  fi
}

# --- 5. systemd units ------------------------------------------------------------

UNITS_TOUCHED=0
OLD_ENABLED=0
SYSTEMD_TODO=""

# transform_unit <old-file> <new-file>: write <new-file> from <old-file>, unless it exists.
transform_unit() {
  local src="$1" dst="$2"
  [ -f "$src" ] || return 0
  [ -e "$dst" ] && return 0
  if [ "$DRY_RUN" = 1 ]; then
    note "would write $dst (from $src)"
  else
    mkdir -p "$(dirname "$dst")"
    rewrite_text <"$src" >"$dst"
    note "wrote $dst"
    UNITS_TOUCHED=1
  fi
}

park() {
  local path="$1"
  [ -e "$path" ] || return 0
  if [ "$DRY_RUN" = 1 ]; then
    note "would move $path aside as ${path##*/}.pre-wardmast"
  else
    rm -rf "$path.pre-wardmast"
    mv "$path" "$path.pre-wardmast"
    note "moved ${path##*/} -> ${path##*/}.pre-wardmast"
    UNITS_TOUCHED=1
  fi
}

migrate_units() {
  local have_systemctl=0
  command -v systemctl >/dev/null 2>&1 && have_systemctl=1

  if [ -f "$UNITS/arbiter.service" ] || [ -d "$UNITS/arbiter.service.d" ]; then
    if [ "$have_systemctl" = 1 ] && systemctl --user is-enabled --quiet arbiter.service 2>/dev/null; then
      OLD_ENABLED=1
    fi
    transform_unit "$UNITS/arbiter.service" "$UNITS/wardmast.service"

    if [ -d "$UNITS/arbiter.service.d" ]; then
      local conf
      for conf in "$UNITS"/arbiter.service.d/*.conf; do
        [ -f "$conf" ] || continue
        transform_unit "$conf" "$UNITS/wardmast.service.d/${conf##*/}"
      done
    fi

    # Disable before the file moves, or systemctl no longer finds the unit.
    if [ "$DRY_RUN" = 1 ]; then
      note "would disable arbiter.service"
    elif [ "$have_systemctl" = 1 ]; then
      systemctl --user disable arbiter.service >/dev/null 2>&1 || true
      note "disabled arbiter.service"
    fi
    park "$UNITS/arbiter.service"
    park "$UNITS/arbiter.service.d"
  fi

  local timer_was_there=0
  if [ -f "$UNITS/arbiter-logrotate.timer" ]; then
    timer_was_there=1
    transform_unit "$UNITS/arbiter-logrotate.service" "$UNITS/wardmast-logrotate.service"
    transform_unit "$UNITS/arbiter-logrotate.timer" "$UNITS/wardmast-logrotate.timer"
    if [ "$DRY_RUN" != 1 ] && [ "$have_systemctl" = 1 ]; then
      systemctl --user disable --now arbiter-logrotate.timer >/dev/null 2>&1 || true
    fi
    park "$UNITS/arbiter-logrotate.service"
    park "$UNITS/arbiter-logrotate.timer"
  fi

  if [ "$DRY_RUN" != 1 ] && [ "$UNITS_TOUCHED" = 1 ] && [ "$have_systemctl" = 1 ]; then
    if ! systemctl --user daemon-reload; then
      SYSTEMD_TODO="systemctl --user daemon-reload"
    fi
    if [ -f "$UNITS/wardmast.service" ] && [ "$OLD_ENABLED" = 1 ]; then
      if systemctl --user enable wardmast.service >/dev/null 2>&1; then
        note "enabled wardmast.service (not started)"
      else
        SYSTEMD_TODO="${SYSTEMD_TODO:+$SYSTEMD_TODO; }systemctl --user enable wardmast.service"
      fi
    fi
    if [ "$timer_was_there" = 1 ] && [ -f "$UNITS/wardmast-logrotate.timer" ]; then
      systemctl --user enable --now wardmast-logrotate.timer >/dev/null 2>&1 || true
    fi
  fi

  for sys in /etc/systemd/system/arbiter.service /etc/systemd/user/arbiter.service; do
    if [ -f "$sys" ]; then
      say "  warning: $sys is a system-wide unit; this script does not use sudo. Reinstall it with"
      say "           \`ward install service --system\` after stopping and disabling the old one."
    fi
  done
}

# --- 6. recorded checkout --------------------------------------------------------

migrate_config_dir() {
  local old_dir="$CONFIG_HOME/arbiter" new_dir="$CONFIG_HOME/wardmast" f
  [ -d "$old_dir" ] || return 0
  if [ "$DRY_RUN" = 1 ]; then
    note "would move $old_dir/* into $new_dir"
    return 0
  fi
  mkdir -p "$new_dir"
  for f in "$old_dir"/*; do
    [ -e "$f" ] || continue
    if [ -e "$new_dir/${f##*/}" ]; then
      say "  keeping $new_dir/${f##*/} (already present); old copy left at $f"
    else
      mv "$f" "$new_dir/"
      note "moved ${f#"$HOME"/} -> ${new_dir#"$HOME"/}/"
    fi
  done
  rmdir "$old_dir" 2>/dev/null || true
}

# The checkout's own .arbiter.env / .run-server.sh (dev-mode installs, where the
# unit runs `mix phx.server` from the source tree).
migrate_checkout() {
  local checkout=""
  [ -f "$CONFIG_HOME/wardmast/home" ] && checkout="$(tr -d '\n' <"$CONFIG_HOME/wardmast/home")"
  [ -n "$checkout" ] && [ -d "$checkout" ] || return 0
  if [ -f "$checkout/.arbiter.env" ] && [ ! -e "$checkout/.wardmast.env" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      note "would rename $checkout/.arbiter.env -> .wardmast.env"
    else
      mv "$checkout/.arbiter.env" "$checkout/.wardmast.env"
      note "renamed $checkout/.arbiter.env -> .wardmast.env"
      rewrite_env_file "$checkout/.wardmast.env"
    fi
  fi
  if [ -f "$checkout/.run-server.sh" ] && grep -q '\.arbiter\.env' "$checkout/.run-server.sh"; then
    if [ "$DRY_RUN" = 1 ]; then
      note "would update $checkout/.run-server.sh to source .wardmast.env"
    else
      sed -i.pre-migrate 's#\.arbiter\.env#.wardmast.env#g' "$checkout/.run-server.sh"
      rm -f "$checkout/.run-server.sh.pre-migrate"
      note "updated $checkout/.run-server.sh to source .wardmast.env"
    fi
  fi
}

# --- run -------------------------------------------------------------------------

HAD_OLD=0
{ [ -e "$OLD" ] || [ -e "$UNITS/arbiter.service" ] || [ -d "$CONFIG_HOME/arbiter" ] ||
  [ -d "$UNITS/arbiter.service.d" ] || [ -e "$NEW/arbiter.env" ]; } && HAD_OLD=1

move_data_home
repoint_links
migrate_env_file
migrate_logs
migrate_units
migrate_config_dir
migrate_checkout

if [ "$CHANGED" = 0 ]; then
  if [ "$HAD_OLD" = 1 ] || [ -d "$NEW" ]; then
    say "already migrated: $NEW is the data home and no Arbiter files remain."
  else
    say "nothing to migrate: no ~/.arbiter install found on this host."
  fi
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  say "dry run complete: nothing was changed."
  exit 0
fi

say ""
say "Migration complete. Next:"
if [ -n "$SYSTEMD_TODO" ]; then
  say "systemd did not accept every call; run these yourself first:"
  say "  $SYSTEMD_TODO"
fi
say "  systemctl --user start wardmast.service"
say "  ward doctor"
say "Update shell profiles / scripts that export ARB_DATA_HOME, ARB_PRIMARY_CHECKOUT or point at ~/.arbiter."
say "Once the server has been healthy for a while, you can delete: ~/.arbiter (the symlink),"
say "  $NEW/wardmast.env.pre-migrate, and the *.pre-wardmast files in $UNITS."
say "A cluster install needs the helm steps: scripts/migrate-from-arbiter.sh --helm-notes"
