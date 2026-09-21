#!/usr/bin/env bash
set -Eeuo pipefail

KINGBASE_HOME="${KINGBASE_HOME:-/opt/Kingbase/ES/V8/Server}"
KINGBASE_BIN="${KINGBASE_BIN:-$KINGBASE_HOME/bin}"
DATA_DIR="${KINGBASE_DATA_DIR:-/var/lib/kingbase/data}"
DATA_ROOT="$(dirname "$DATA_DIR")"
DB_PORT="${KINGBASE_PORT:-54321}"
DB_SUPERUSER="${KINGBASE_SUPERUSER:-system}"
DB_PASSWORD="${KINGBASE_PASSWORD:-}"
DB_NAME="${KINGBASE_DATABASE:-kingbase}"
REPL_USER="${KINGBASE_REPLICATION_USER:-replication}"
REPL_PASSWORD="${KINGBASE_REPLICATION_PASSWORD:-}"
PRIMARY_HOST="${KINGBASE_PRIMARY_HOST:-kingbase-rw}"
REJOIN_PRIMARY_HOST="${KINGBASE_REJOIN_PRIMARY_HOST:-$PRIMARY_HOST}"
INITDB_BIN="${KINGBASE_INITDB_BIN:-$KINGBASE_BIN/initdb}"
SYS_CTL_BIN="${KINGBASE_SYS_CTL_BIN:-$KINGBASE_BIN/sys_ctl}"
KSQL_BIN="${KINGBASE_KSQL_BIN:-$KINGBASE_BIN/ksql}"
BASEBACKUP_BIN="${KINGBASE_BASEBACKUP_BIN:-$KINGBASE_BIN/sys_basebackup}"
REWIND_BIN="${KINGBASE_REWIND_BIN:-$KINGBASE_BIN/sys_rewind}"
CONF_FILE="${KINGBASE_CONF_FILE:-$DATA_DIR/kingbase.conf}"
HBA_FILE="${KINGBASE_HBA_FILE:-$DATA_DIR/sys_hba.conf}"
ENCPWD_BIN="${KINGBASE_ENCPWD_BIN:-$KINGBASE_BIN/sys_encpwd}"
DEMOTED_MARKER="$DATA_ROOT/ha-demoted"
RESTORE_MARKER="$DATA_ROOT/restore-from-basebackup"
HA_MANAGER="${KINGBASE_HA_MANAGER:-/usr/local/bin/kingbase-ha-manager.py}"
TLS_ENABLED="${KINGBASE_TLS_ENABLED:-0}"
TLS_SOURCE_DIR="${KINGBASE_TLS_SOURCE_DIR:-/etc/kingbase/tls}"
TLS_DIR="$DATA_ROOT/tls"
TLS_CERT_FILE="$TLS_DIR/server.crt"
TLS_KEY_FILE="$TLS_DIR/server.key"
TLS_CA_FILE="$TLS_DIR/ca.crt"
LICENSE_SOURCE_DIR="${KINGBASE_LICENSE_SOURCE_DIR:-/opt/Kingbase/license}"
LICENSE_FILE_NAME="${KINGBASE_LICENSE_FILE_NAME:-license.dat}"
LICENSE_REQUIRED="${KINGBASE_LICENSE_REQUIRED:-1}"
REPL_SSLMODE="${KINGBASE_REPLICATION_SSLMODE:-verify-ca}"
KINGBASE_USER_HOME="${KINGBASE_USER_HOME:-/home/kingbase}"

export KINGBASE_PASSWORD="$DB_PASSWORD"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

run_as_kingbase() {
  local user_env=(env "HOME=$KINGBASE_USER_HOME" "USER=kingbase" "LOGNAME=kingbase")
  if [ "$(id -u)" = "0" ]; then
    if command -v setpriv >/dev/null 2>&1; then
      setpriv --reuid=kingbase --regid=kingbase --init-groups "${user_env[@]}" "$@"
    else
      runuser -u kingbase -- "${user_env[@]}" "$@"
    fi
  else
    "${user_env[@]}" "$@"
  fi
}

pod_ordinal() {
  local name="${POD_NAME:-${HOSTNAME:-kingbase-0}}"
  printf '%s' "${name##*-}"
}

require_safe_identifier() {
  case "$1" in
    ''|[0-9]*|*[!a-zA-Z0-9_]*)
      log "invalid SQL identifier: $1"
      exit 1
      ;;
  esac
}

require_passwords() {
  [ -n "$DB_PASSWORD" ] || { log "KINGBASE_PASSWORD is required"; exit 1; }
  [ -n "$REPL_PASSWORD" ] || { log "KINGBASE_REPLICATION_PASSWORD is required"; exit 1; }
  require_safe_identifier "$DB_SUPERUSER"
  require_safe_identifier "$REPL_USER"
  require_safe_identifier "$DB_NAME"
}

data_dir_initialized() {
  # KingbaseES V9 uses SYS_VERSION rather than PostgreSQL's PG_VERSION.
  [ -s "$DATA_DIR/SYS_VERSION" ] && [ -s "$DATA_DIR/global/sys_control" ] && [ -s "$CONF_FILE" ]
}

data_dir_empty() {
  [ -z "$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

prepare_dirs() {
  mkdir -p "$DATA_ROOT" "$DATA_DIR"
  if [ "$(id -u)" = "0" ]; then
    chown -R kingbase:kingbase "$DATA_ROOT"
  fi
}

prepare_tls() {
  [ "$TLS_ENABLED" = "1" ] || return 0
  for name in tls.crt tls.key ca.crt; do
    [ -s "$TLS_SOURCE_DIR/$name" ] || { log "missing TLS file: $TLS_SOURCE_DIR/$name"; exit 1; }
  done
  mkdir -p "$TLS_DIR"
  cp "$TLS_SOURCE_DIR/tls.crt" "$TLS_CERT_FILE"
  cp "$TLS_SOURCE_DIR/tls.key" "$TLS_KEY_FILE"
  cp "$TLS_SOURCE_DIR/ca.crt" "$TLS_CA_FILE"
  chmod 0644 "$TLS_CERT_FILE" "$TLS_CA_FILE"
  chmod 0600 "$TLS_KEY_FILE"
  if [ "$(id -u)" = "0" ]; then
    chown -R kingbase:kingbase "$TLS_DIR"
  fi
}

prepare_license() {
  local source="$LICENSE_SOURCE_DIR/$LICENSE_FILE_NAME"
  if [ ! -s "$source" ]; then
    [ "$LICENSE_REQUIRED" = "1" ] && {
      log "missing Kingbase license file: $source"
      exit 1
    }
    return 0
  fi
  cp "$source" "$KINGBASE_BIN/license.dat"
  chmod 0644 "$KINGBASE_BIN/license.dat"
  if [ "$(id -u)" = "0" ]; then
    chown kingbase:kingbase "$KINGBASE_BIN/license.dat"
  fi
}

write_encrypted_replication_password() {
  local host="$1"
  [ -x "$ENCPWD_BIN" ] || { log "sys_encpwd is required for persistent replication authentication"; exit 1; }
  if ! run_as_kingbase "$ENCPWD_BIN" -H "$host" -P "$DB_PORT" -D replication \
    -U "$REPL_USER" -W "$REPL_PASSWORD" >/dev/null 2>&1; then
    log "failed to update encrypted replication credentials for $host"
    exit 1
  fi
}

configured_primary_host() {
  local file line
  for file in "$DATA_DIR/kingbase.auto.conf" "$CONF_FILE"; do
    [ -f "$file" ] || continue
    while IFS= read -r line; do
      if [[ "$line" =~ host=([^[:space:]\'\"]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
      fi
    done < <(grep -E '^[[:space:]]*primary_conninfo[[:space:]]*=' "$file" || true)
  done
  return 1
}

remove_conf_block() {
  local file="$1" start="$2" end="$3" tmp
  tmp="$(mktemp)"
  awk -v start="$start" -v end="$end" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

configure_hba() {
  local tmp host_prefix
  touch "$HBA_FILE"
  tmp="$(mktemp)"
  awk -v user="$REPL_USER" '
    $0 == "# BEGIN kubeblocks-switchover-fence" { fence = 1; next }
    $0 == "# END kubeblocks-switchover-fence" { fence = 0; next }
    fence { next }
    $1 ~ /^host/ && $2 == "replication" && $3 == user { next }
    $1 ~ /^host/ && $2 == "all" && $3 == "all" && \
      ($4 == "127.0.0.1/32" || $4 == "::1/128" || $4 == "0.0.0.0/0" || $4 == "::/0") { next }
    { print }
  ' "$HBA_FILE" > "$tmp"
  host_prefix="host"
  [ "$TLS_ENABLED" = "1" ] && host_prefix="hostssl"
  {
    printf 'host all all 127.0.0.1/32 md5\n'
    printf 'host all all ::1/128 md5\n'
    printf '%s replication %s 0.0.0.0/0 md5\n' "$host_prefix" "$REPL_USER"
    printf '%s replication %s ::/0 md5\n' "$host_prefix" "$REPL_USER"
    printf '%s all all 0.0.0.0/0 md5\n' "$host_prefix"
    printf '%s all all ::/0 md5\n' "$host_prefix"
    cat "$tmp"
  } > "$HBA_FILE"
  rm -f "$tmp"
}

configure_server() {
  mkdir -p "$DATA_DIR"
  touch "$CONF_FILE"
  remove_conf_block "$CONF_FILE" "# BEGIN kubeblocks-ha" "# END kubeblocks-ha"
  cat >> "$CONF_FILE" <<EOF

# BEGIN kubeblocks-ha
listen_addresses = '*'
port = $DB_PORT
wal_level = replica
wal_log_hints = on
full_page_writes = on
max_wal_senders = ${KINGBASE_MAX_WAL_SENDERS:-16}
max_replication_slots = ${KINGBASE_MAX_REPLICATION_SLOTS:-16}
wal_keep_segments = ${KINGBASE_WAL_KEEP_SEGMENTS:-512}
hot_standby = on
synchronous_commit = '${KINGBASE_SYNCHRONOUS_COMMIT:-on}'
synchronous_standby_names = '${KINGBASE_SYNCHRONOUS_STANDBY_NAMES:-ANY 1 (*)}'
logging_collector = on
log_directory = 'log'
log_filename = 'kingbase-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_truncate_on_rotation = on
EOF
  if [ "$TLS_ENABLED" = "1" ]; then
    cat >> "$CONF_FILE" <<EOF
ssl = on
ssl_cert_file = '$TLS_CERT_FILE'
ssl_key_file = '$TLS_KEY_FILE'
ssl_ca_file = '$TLS_CA_FILE'
EOF
  fi
  if [ -f /etc/kingbase/user-config/kingbase-user.conf ]; then
    printf "include_if_exists = '/etc/kingbase/user-config/kingbase-user.conf'\n" >> "$CONF_FILE"
  fi
  printf '%s\n' "# END kubeblocks-ha" >> "$CONF_FILE"
  configure_hba
}

primary_conninfo() {
  local conninfo
  conninfo="host=$1 port=$DB_PORT user=$REPL_USER application_name=${POD_NAME:-${HOSTNAME:-kingbase}}"
  if [ "$TLS_ENABLED" = "1" ]; then
    conninfo="$conninfo sslmode=$REPL_SSLMODE sslrootcert=$TLS_CA_FILE"
  fi
  printf '%s' "$conninfo"
}

superuser_conninfo() {
  local conninfo
  conninfo="host=$1 port=$DB_PORT user=$DB_SUPERUSER"
  if [ "$TLS_ENABLED" = "1" ]; then
    conninfo="$conninfo sslmode=$REPL_SSLMODE sslrootcert=$TLS_CA_FILE"
  fi
  printf '%s' "$conninfo"
}

configure_standby() {
  local host="$1"
  remove_conf_block "$CONF_FILE" "# BEGIN kubeblocks-primary-conninfo" "# END kubeblocks-primary-conninfo"
  {
    printf '\n# BEGIN kubeblocks-primary-conninfo\n'
    printf "primary_conninfo = '%s'\n" "$(primary_conninfo "$host")"
    printf '# END kubeblocks-primary-conninfo\n'
  } >> "$CONF_FILE"
  touch "$DATA_DIR/standby.signal"
  if [ "$(id -u)" = "0" ]; then
    chown -R kingbase:kingbase "$DATA_DIR"
  fi
}

remote_ksql() {
  local host="$1"
  shift
  if [ "$TLS_ENABLED" = "1" ]; then
    KINGBASE_SSLMODE="$REPL_SSLMODE" KINGBASE_SSLROOTCERT="$TLS_CA_FILE" KINGBASE_PASSWORD="$DB_PASSWORD" \
      "$KSQL_BIN" -h "$host" -p "$DB_PORT" -U "$DB_SUPERUSER" -d template1 "$@"
  else
    KINGBASE_SSLMODE=disable KINGBASE_PASSWORD="$DB_PASSWORD" \
      "$KSQL_BIN" -h "$host" -p "$DB_PORT" -U "$DB_SUPERUSER" -d template1 "$@"
  fi
}

primary_reachable() {
  remote_ksql "$PRIMARY_HOST" -At -c 'select case when pg_is_in_recovery() then 0 else 1 end' 2>/dev/null \
    | grep -qx '1'
}

wait_for_primary() {
  local host="${1:-$PRIMARY_HOST}" timeout="${KINGBASE_PRIMARY_WAIT_SECONDS:-900}" started now
  started="$(date +%s)"
  log "waiting for primary ${host}:${DB_PORT}"
  while ! remote_ksql "$host" -At -c 'select case when pg_is_in_recovery() then 0 else 1 end' 2>/dev/null | grep -qx '1'; do
    now="$(date +%s)"
    if [ $((now - started)) -ge "$timeout" ]; then
      log "timed out waiting for writable primary ${host}:${DB_PORT}"
      exit 1
    fi
    sleep 5
  done
}

start_db() {
  # sys_ctl passes this to the postmaster and its WAL receiver. The entrypoint
  # and HA manager retain the system password for local management operations.
  KINGBASE_PASSWORD="$REPL_PASSWORD" run_as_kingbase "$SYS_CTL_BIN" -D "$DATA_DIR" -w -t "${KINGBASE_START_TIMEOUT_SECONDS:-300}" start
}

stop_db() {
  run_as_kingbase "$SYS_CTL_BIN" -D "$DATA_DIR" -m fast -w stop || true
}

ksql() {
  KINGBASE_SSLMODE=disable KINGBASE_PASSWORD="$DB_PASSWORD" run_as_kingbase "$KSQL_BIN" \
    -h /tmp -p "$DB_PORT" -U "$DB_SUPERUSER" -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"
}

create_replication_user() {
  local escaped
  escaped="${REPL_PASSWORD//\'/\'\'}"
  ksql -c "DO \$\$ BEGIN CREATE ROLE $REPL_USER WITH LOGIN REPLICATION PASSWORD '$escaped'; EXCEPTION WHEN duplicate_object THEN ALTER ROLE $REPL_USER WITH LOGIN REPLICATION PASSWORD '$escaped'; END \$\$;"
}

create_default_database() {
  [ "$DB_NAME" != "template1" ] && [ "$DB_NAME" != "template0" ] || return 0
  if ksql -d template1 -At -c "select 1 from pg_database where datname = '$DB_NAME'" | grep -qx 1; then
    return 0
  fi
  KINGBASE_SSLMODE=disable KINGBASE_PASSWORD="$DB_PASSWORD" run_as_kingbase "$KINGBASE_BIN/createdb" \
    -h 127.0.0.1 -p "$DB_PORT" -U "$DB_SUPERUSER" "$DB_NAME"
}

init_primary() {
  require_passwords
  data_dir_empty || { log "refusing to initialize primary over non-empty data directory"; exit 1; }
  log "initializing the first primary in $DATA_DIR"
  local pwfile
  pwfile="$(mktemp)"
  printf '%s\n' "$DB_PASSWORD" > "$pwfile"
  chmod 0600 "$pwfile"
  if [ "$(id -u)" = "0" ]; then
    chown kingbase:kingbase "$pwfile"
  fi
  run_as_kingbase "$INITDB_BIN" -D "$DATA_DIR" -U "$DB_SUPERUSER" --pwfile="$pwfile" ${KINGBASE_INITDB_EXTRA_ARGS:-}
  rm -f "$pwfile"
  KINGBASE_SYNCHRONOUS_COMMIT=local KINGBASE_SYNCHRONOUS_STANDBY_NAMES='' configure_server
  start_db
  create_default_database
  create_replication_user
  stop_db
  configure_server
}

prepare_restored_data() {
  data_dir_initialized || { log "restored backup is not an initialized data directory"; exit 1; }
  if [ "$(pod_ordinal)" = "0" ] && "$HA_MANAGER" bootstrap-acquire; then
    log "restored member acquired bootstrap authority"
    configure_server
    rm -f "$DATA_DIR/standby.signal" "$DATA_DIR/recovery.signal"
  else
    case "$DATA_DIR" in
      ''|/)
        log "refusing to rebuild an unsafe data directory: $DATA_DIR"
        exit 1
        ;;
    esac
    log "rebuilding restored standby from the new primary"
    find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    init_standby "$PRIMARY_HOST"
  fi
  rm -f "$RESTORE_MARKER"
}

init_standby() {
  local host="${1:-$PRIMARY_HOST}" sslmode basebackup_conninfo
  require_passwords
  data_dir_empty || { log "refusing to clone standby over non-empty data directory"; exit 1; }
  wait_for_primary "$host"
  log "cloning standby from $host"
  sslmode="$([ "$TLS_ENABLED" = 1 ] && printf '%s' "$REPL_SSLMODE" || printf disable)"
  basebackup_conninfo="host=$host port=$DB_PORT user=$REPL_USER dbname=template1 sslmode=$sslmode"
  if [ "$TLS_ENABLED" = "1" ]; then
    basebackup_conninfo="$basebackup_conninfo sslrootcert=$TLS_CA_FILE"
  fi
  KINGBASE_PASSWORD="$REPL_PASSWORD" KINGBASE_SSLMODE="$sslmode" \
    KINGBASE_SSLROOTCERT="$TLS_CA_FILE" run_as_kingbase "$BASEBACKUP_BIN" \
      -d "$basebackup_conninfo" -D "$DATA_DIR" -X stream -R -P -w
  configure_server
  configure_standby "$host"
}

rewind_as_standby() {
  [ "${KINGBASE_REJOIN_USE_REWIND:-1}" = "1" ] || return 1
  [ -x "$REWIND_BIN" ] || return 1
  wait_for_primary "$REJOIN_PRIMARY_HOST"
  log "rewinding demoted primary from $REJOIN_PRIMARY_HOST"
  KINGBASE_PASSWORD="$DB_PASSWORD" KINGBASE_SSLMODE="$([ "$TLS_ENABLED" = 1 ] && printf '%s' "$REPL_SSLMODE" || printf disable)" \
    KINGBASE_SSLROOTCERT="$TLS_CA_FILE" run_as_kingbase "$REWIND_BIN" -D "$DATA_DIR" \
      --source-server="$(superuser_conninfo "$REJOIN_PRIMARY_HOST") dbname=$DB_NAME" || return 1
  configure_server
  configure_standby "$REJOIN_PRIMARY_HOST"
}

full_rebuild_as_standby() {
  [ "${KINGBASE_REBUILD_DEMOTED:-0}" = "1" ] || {
    log "automatic full rebuild is disabled; manual recovery is required"
    exit 1
  }
  local failed_dir
  failed_dir="$DATA_ROOT/failed-$(date -u +%Y%m%dT%H%M%SZ)"
  log "rewind failed; preserving old data at $failed_dir before full clone"
  mv "$DATA_DIR" "$failed_dir"
  mkdir -p "$DATA_DIR"
  if [ "$(id -u)" = "0" ]; then
    chown kingbase:kingbase "$DATA_DIR"
  fi
  init_standby "$REJOIN_PRIMARY_HOST"
}

rejoin_demoted() {
  rewind_as_standby || full_rebuild_as_standby
  rm -f "$DEMOTED_MARKER"
}

bootstrap_or_clone() {
  if primary_reachable; then
    init_standby "$PRIMARY_HOST"
    return
  fi
  if [ "$(pod_ordinal)" = "0" ] && "$HA_MANAGER" bootstrap-acquire; then
    init_primary
    return
  fi
  init_standby "$PRIMARY_HOST"
}

monitor_processes() {
  local manager_pid="$1"
  while true; do
    if ! kill -0 "$manager_pid" 2>/dev/null; then
      log "HA manager exited; stopping database"
      stop_db
      return 1
    fi
    if ! KINGBASE_SSLMODE=disable KINGBASE_PASSWORD="$DB_PASSWORD" "$KSQL_BIN" \
      -h /tmp -p "$DB_PORT" -U "$DB_SUPERUSER" -d template1 -At -c 'select 1' >/dev/null 2>&1; then
      log "database health check failed"
      if [ -f "$DEMOTED_MARKER" ]; then
        sleep "${KINGBASE_HA_HANDOFF_GRACE_SECONDS:-5}"
      fi
      return 1
    fi
    sleep "${KINGBASE_MONITOR_INTERVAL_SECONDS:-5}"
  done
}

preflight_primary_start() {
  [ -f "$DATA_DIR/standby.signal" ] && return 0
  local status
  set +e
  "$HA_MANAGER" preflight-authority
  status=$?
  set -e
  case "$status" in
    0)
      return 0
      ;;
    2)
      log "write authority belongs elsewhere; rebuilding this former primary as a standby"
      touch "$DEMOTED_MARKER"
      rejoin_demoted
      ;;
    *)
      log "write authority could not be checked; refusing to start a possible primary"
      return 1
      ;;
  esac
}

run_managed_db() {
  local manager_pid
  preflight_primary_start
  start_db
  "$HA_MANAGER" &
  manager_pid=$!
  trap 'log "received termination signal"; kill "$manager_pid" 2>/dev/null || true; stop_db; wait "$manager_pid" 2>/dev/null || true; exit 0' TERM INT
  monitor_processes "$manager_pid"
}

main() {
  if [ "${1:-kingbase}" != "kingbase" ]; then
    exec "$@"
  fi
  require_passwords
  prepare_dirs
  prepare_license
  prepare_tls

  if [ -f "$DEMOTED_MARKER" ]; then
    rejoin_demoted
  elif [ -f "$RESTORE_MARKER" ] && data_dir_initialized; then
    log "starting from a KubeBlocks base backup restore"
    prepare_restored_data
  elif data_dir_initialized; then
    log "existing initialized data directory found"
    configure_server
  elif data_dir_empty; then
    bootstrap_or_clone
  else
    log "data directory is non-empty but incomplete; refusing destructive initialization"
    exit 1
  fi

  if configured_host="$(configured_primary_host)"; then
    write_encrypted_replication_password "$configured_host"
  fi

  log "starting KingbaseES under HA supervision"
  run_managed_db
}

if [ "${KINGBASE_ENTRYPOINT_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
