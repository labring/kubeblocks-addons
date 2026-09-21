import pathlib
import subprocess
import tempfile
import unittest


ENTRYPOINT_PATH = pathlib.Path(__file__).parents[1] / "docker-entrypoint.sh"


class EntrypointTests(unittest.TestCase):
    def test_start_db_passes_replication_password_to_postmaster_only(self):
        script = r'''
export KINGBASE_ENTRYPOINT_SOURCE_ONLY=1
source "$1"
REPL_PASSWORD=replication-marker
SYS_CTL_BIN=/test/sys_ctl
KINGBASE_START_TIMEOUT_SECONDS=42
run_as_kingbase() {
  printf '%s|%s\n' "$KINGBASE_PASSWORD" "$*"
}
test "$(start_db)" = "replication-marker|/test/sys_ctl -D /var/lib/kingbase/data -w -t 42 start"
test "$KINGBASE_PASSWORD" = "$DB_PASSWORD"
'''
        subprocess.run(
            ["bash", "-ec", script, "bash", str(ENTRYPOINT_PATH)],
            check=True,
            capture_output=True,
            text=True,
        )

    def test_restored_standby_is_recloned_from_new_primary(self):
        script = r'''
export KINGBASE_ENTRYPOINT_SOURCE_ONLY=1
source "$1"
DATA_ROOT="$2"
DATA_DIR="$DATA_ROOT/data"
RESTORE_MARKER="$DATA_ROOT/restore-from-basebackup"
POD_NAME=kingbase-restore-kingbase-1
PRIMARY_HOST=kingbase-rw
mkdir -p "$DATA_DIR"
touch "$DATA_DIR/SYS_VERSION" "$DATA_DIR/stale-restored-file" "$RESTORE_MARKER"
data_dir_initialized() { return 0; }
init_standby() {
  test "$1" = kingbase-rw
  test -z "$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 -print -quit)"
  touch "$DATA_DIR/recloned-from-primary"
}
prepare_restored_data
test -f "$DATA_DIR/recloned-from-primary"
test ! -e "$DATA_DIR/stale-restored-file"
test ! -e "$RESTORE_MARKER"
'''
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(
                ["bash", "-ec", script, "bash", str(ENTRYPOINT_PATH), directory],
                check=True,
                capture_output=True,
                text=True,
            )
