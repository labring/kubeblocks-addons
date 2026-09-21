#!/usr/bin/env python3
"""Small dependency-free Prometheus exporter for the HA control plane."""

import http.server
import os
import subprocess


HOME = os.environ.get("KINGBASE_HOME", "/opt/Kingbase/ES/V8/Server")
KSQL = os.environ.get("KINGBASE_KSQL_BIN", os.path.join(HOME, "bin", "ksql"))
PORT = os.environ.get("KINGBASE_PORT", "54321")
USER = os.environ.get("KINGBASE_SUPERUSER", "system")
PASSWORD = os.environ.get("KINGBASE_PASSWORD", "")
DATABASE = os.environ.get("KINGBASE_DATABASE", "kingbase")
HTTP_PORT = int(os.environ.get("KINGBASE_EXPORTER_PORT", "9187"))
LABELS = {
    "namespace": os.environ.get("POD_NAMESPACE", "default"),
    "cluster": os.environ.get("KINGBASE_CLUSTER_NAME", "unknown"),
    "component": os.environ.get("KINGBASE_COMPONENT_NAME", "kingbase"),
    "pod": os.environ.get("POD_NAME", "unknown"),
}


def query(sql):
    env = os.environ.copy()
    env["KINGBASE_PASSWORD"] = PASSWORD
    env["KINGBASE_SSLMODE"] = "disable"
    result = subprocess.run(
        [KSQL, "-h", "127.0.0.1", "-p", PORT, "-U", USER, "-d", DATABASE, "-At", "-F", "|", "-c", sql],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=5,
        check=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def escape(value):
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def label_text(extra=None):
    values = dict(LABELS)
    values.update(extra or {})
    return ",".join(f'{key}="{escape(str(value))}"' for key, value in values.items())


def metrics():
    lines = ["# HELP kingbase_up Whether the local KingbaseES SQL endpoint is reachable.", "# TYPE kingbase_up gauge"]
    try:
        recovery = query("select pg_is_in_recovery()")[-1].lower() in ("t", "true", "1")
    except Exception:
        lines.append(f"kingbase_up{{{label_text()}}} 0")
        return ("\n".join(lines) + "\n").encode("utf-8")

    lines.append(f"kingbase_up{{{label_text()}}} 1")
    lines.extend(["# HELP kingbase_role Current database role.", "# TYPE kingbase_role gauge"])
    lines.append(f'kingbase_role{{{label_text({"role": "primary"})}}} {0 if recovery else 1}')
    lines.append(f'kingbase_role{{{label_text({"role": "standby"})}}} {1 if recovery else 0}')
    try:
        lines.extend([
            "# HELP kingbase_replication_connected_standbys Streaming standbys connected to this primary.",
            "# TYPE kingbase_replication_connected_standbys gauge",
        ])
        connected = 0 if recovery else int(query("select count(*) from pg_stat_replication where state = 'streaming'")[-1])
        lines.append(f"kingbase_replication_connected_standbys{{{label_text()}}} {connected}")
    except Exception:
        pass
    try:
        lines.extend(["# HELP kingbase_replication_lag_bytes Replication replay lag in bytes.", "# TYPE kingbase_replication_lag_bytes gauge"])
        if recovery:
            lag = query("select greatest(coalesce(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()), 0), 0)::bigint")[-1]
            lines.append(f'kingbase_replication_lag_bytes{{{label_text({"standby": LABELS["pod"]})}}} {lag}')
        else:
            rows = query("select application_name, greatest(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn), 0)::bigint from pg_stat_replication")
            for row in rows:
                standby, lag = row.split("|", 1)
                lines.append(f'kingbase_replication_lag_bytes{{{label_text({"standby": standby})}}} {lag}')
    except Exception:
        pass
    return ("\n".join(lines) + "\n").encode("utf-8")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/metrics", "/healthz"):
            self.send_response(404)
            self.end_headers()
            return
        body = b"ok\n" if self.path == "/healthz" else metrics()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), Handler).serve_forever()
