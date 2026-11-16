#!/bin/bash
set -e
set -o pipefail

mysql_query_for_backup() {
  local mysql_user="${DP_DB_USER:-root}"
  local mysql_password="${DP_DB_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
  local mysql_host="${DP_DB_HOST:-}"
  local mysql_port="${DP_DB_PORT:-3306}"

  if [ -z "${mysql_host}" ]; then
    echo "ERROR: DP_DB_HOST is not set; cannot check MySQL instant DDL row versions." >&2
    return 1
  fi

  MYSQL_PWD="${mysql_password}" mysql --protocol=tcp --default-character-set=utf8mb4 --batch --skip-column-names --connect-timeout=10 -u "${mysql_user}" -h "${mysql_host}" -P "${mysql_port}" -e "$1"
}

mysql_query_file_for_backup() {
  local sql_file="$1"
  local mysql_user="${DP_DB_USER:-root}"
  local mysql_password="${DP_DB_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
  local mysql_host="${DP_DB_HOST:-}"
  local mysql_port="${DP_DB_PORT:-3306}"

  if [ -z "${mysql_host}" ]; then
    echo "ERROR: DP_DB_HOST is not set; cannot check MySQL instant DDL row versions." >&2
    return 1
  fi

  MYSQL_PWD="${mysql_password}" mysql --protocol=tcp --default-character-set=utf8mb4 --batch --skip-column-names --connect-timeout=10 -u "${mysql_user}" -h "${mysql_host}" -P "${mysql_port}" <"${sql_file}"
}

mysql_escape_identifier() {
  local value="$1"
  local quote=$'\140'
  value="${value//${quote}/${quote}${quote}}"
  printf "%s" "${value}"
}

mysql_quote_qualified_identifier() {
  local schema
  local table
  local quote=$'\140'

  schema="$(mysql_escape_identifier "$1")"
  table="$(mysql_escape_identifier "$2")"
  printf "%s%s%s.%s%s%s" "${quote}" "${schema}" "${quote}" "${quote}" "${table}" "${quote}"
}

# INNODB_TABLES.NAME uses MySQL filename encoding for characters such as
# spaces, punctuation, literal @ signs, and uncased Unicode characters.
# Decode the @hhhh escapes before using these names as SQL identifiers.
mysql_decode_filename_identifier() {
  local encoded="$1"
  local decoded=""
  local LC_CTYPE=en_US.utf8
  local character
  local codepoint

  while [ -n "${encoded}" ]; do
    if [[ "${encoded}" =~ ^@([[:xdigit:]]{4}) ]]; then
      codepoint="${BASH_REMATCH[1]}"
      printf -v character "%b" "\\u${codepoint}"
      decoded+="${character}"
      encoded="${encoded:5}"
    else
      character="${encoded:0:1}"
      decoded+="${character}"
      encoded="${encoded:1}"
    fi
  done

  printf "%s" "${decoded}"
}

run_mysql_rebuild_statement() {
  local description="$1"
  local sql="$2"
  local output_file="$3"
  local sql_file="/tmp/mysql-instant-ddl-sql.$$"

  cat >"${sql_file}" <<EOF
SET SESSION sql_log_bin=0;
${sql}
EOF

  if mysql_query_file_for_backup "${sql_file}" >"${output_file}" 2>&1; then
    sed 's/^/INFO: mysql: /' "${output_file}" || true
    rm -f "${sql_file}"
    return 0
  fi

  echo "WARNING: ${description} failed:"
  sed 's/^/WARNING: mysql: /' "${output_file}" || true
  rm -f "${sql_file}"
  return 1
}

rebuild_mysql_instant_ddl_table() {
  local qualified_table="$1"
  local output_file="$2"

  echo "INFO: rebuilding ${qualified_table} to clear instant DDL row versions..."

  if run_mysql_rebuild_statement \
    "OPTIMIZE NO_WRITE_TO_BINLOG TABLE ${qualified_table}" \
    "OPTIMIZE NO_WRITE_TO_BINLOG TABLE ${qualified_table};" \
    "${output_file}"; then
    return 0
  fi

  if run_mysql_rebuild_statement \
    "ALTER TABLE ${qualified_table} FORCE, ALGORITHM=COPY" \
    "ALTER TABLE ${qualified_table} FORCE, ALGORITHM=COPY;" \
    "${output_file}"; then
    return 0
  fi

  run_mysql_rebuild_statement \
    "ALTER TABLE ${qualified_table} ENGINE=InnoDB, ALGORITHM=COPY" \
    "ALTER TABLE ${qualified_table} ENGINE=InnoDB, ALGORITHM=COPY;" \
    "${output_file}"
}

fix_mysql_instant_ddl_tables() {
  local table_list="/tmp/mysql-instant-ddl-tables.$$"
  local output_file="/tmp/mysql-instant-ddl-output.$$"
  local remaining_list="/tmp/mysql-instant-ddl-remaining.$$"
  local count
  local failed=0
  local repaired=0

  echo "INFO: checking MySQL tables with instant DDL row versions before xtrabackup..."

  if ! mysql_query_for_backup "SELECT NAME FROM INFORMATION_SCHEMA.INNODB_TABLES WHERE TOTAL_ROW_VERSIONS > 0 ORDER BY NAME;" >"${table_list}"; then
    echo "ERROR: failed to query INFORMATION_SCHEMA.INNODB_TABLES for TOTAL_ROW_VERSIONS." >&2
    rm -f "${table_list}" "${output_file}" "${remaining_list}"
    return 1
  fi

  count=$(wc -l <"${table_list}" | tr -d " ")
  if [ "${count:-0}" -eq 0 ] 2>/dev/null; then
    echo "INFO: no tables with instant DDL row versions found."
    rm -f "${table_list}" "${output_file}" "${remaining_list}"
    return 0
  fi

  echo "INFO: found ${count} table(s) with instant DDL row versions:"
  sed 's/^/INFO:   - /' "${table_list}" || true

  while IFS= read -r innodb_name; do
    [ -z "${innodb_name}" ] && continue

    if [ "${innodb_name}" = "${innodb_name#*/}" ]; then
      echo "ERROR: unexpected INNODB_TABLES.NAME format: ${innodb_name}" >&2
      failed=$((failed + 1))
      continue
    fi

    local schema_encoded="${innodb_name%%/*}"
    local table_encoded="${innodb_name#*/}"
    local schema
    local table
    local schema_escaped
    local table_escaped
    local qualified_table

    schema="$(mysql_decode_filename_identifier "${schema_encoded}")"
    table="$(mysql_decode_filename_identifier "${table_encoded}")"
    qualified_table="$(mysql_quote_qualified_identifier "${schema}" "${table}")"

    if ! rebuild_mysql_instant_ddl_table "${qualified_table}" "${output_file}"; then
      echo "ERROR: failed to rebuild ${qualified_table}; xtrabackup would still fail."
      failed=$((failed + 1))
      continue
    fi

    echo "INFO: ${qualified_table} rebuild statement succeeded."
    repaired=$((repaired + 1))
  done <"${table_list}"

  if ! mysql_query_for_backup "SELECT NAME FROM INFORMATION_SCHEMA.INNODB_TABLES WHERE TOTAL_ROW_VERSIONS > 0 ORDER BY NAME;" >"${remaining_list}"; then
    echo "ERROR: failed to verify remaining instant DDL row versions." >&2
    rm -f "${table_list}" "${output_file}" "${remaining_list}"
    return 1
  fi

  if [ -s "${remaining_list}" ]; then
    echo "ERROR: MySQL still has tables with instant DDL row versions after rebuild attempts:"
    sed 's/^/ERROR:   - /' "${remaining_list}" || true
    rm -f "${table_list}" "${output_file}" "${remaining_list}"
    return 1
  fi

  if [ "${failed}" -ne 0 ]; then
    echo "ERROR: ${failed} table rebuild attempt(s) failed; aborting backup before xtrabackup."
    rm -f "${table_list}" "${output_file}" "${remaining_list}"
    return 1
  fi

  echo "INFO: cleared instant DDL row versions for ${repaired} table(s), waiting for storage state to settle..."
  rm -f "${table_list}" "${output_file}" "${remaining_list}"
  sleep 10
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  fix_mysql_instant_ddl_tables
fi
