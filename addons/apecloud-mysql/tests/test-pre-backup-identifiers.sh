#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../dataprotection" && pwd)"
source "${script_dir}/pre-backup.sh"

assert_equal() {
  local expected="$1"
  local actual="$2"
  local name="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'FAIL: %s\nexpected: <%s>\nactual:   <%s>\n' "${name}" "${expected}" "${actual}" >&2
    exit 1
  fi
  printf 'PASS: %s\n' "${name}"
}

assert_equal "db-with-hyphen" "$(mysql_decode_filename_identifier 'db@002dwith@002dhyphen')" "decode hyphens"
assert_equal "db with space" "$(mysql_decode_filename_identifier 'db@0020with@0020space')" "decode spaces"
assert_equal 'db@literal' "$(mysql_decode_filename_identifier 'db@0040literal')" "decode literal at sign"
assert_equal 'table@002d' "$(mysql_decode_filename_identifier 'table@0040002d')" "preserve literal at escape-looking text"
assert_equal 'table.dot' "$(mysql_decode_filename_identifier 'table@002edot')" "decode dot"
assert_equal 'table$#()' "$(mysql_decode_filename_identifier 'table@0024@0023@0028@0029')" "decode punctuation"
assert_equal '中文表' "$(mysql_decode_filename_identifier '@4e2d@6587@8868')" "decode Chinese identifiers as UTF-8"

tick=$(printf '\140')
expected="${tick}db@literal${tick}.${tick}table${tick}${tick}tick${tick}"
actual="$(mysql_quote_qualified_identifier 'db@literal' "table${tick}tick")"
assert_equal "${expected}" "${actual}" "quote identifiers and escape embedded backticks"
