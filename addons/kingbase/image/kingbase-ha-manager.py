#!/usr/bin/env python3
"""Lease-based KingbaseES HA supervisor for KubeBlocks 0.8."""

import datetime
import decimal
import http.server
import hmac
import json
import os
import re
import shutil
import socketserver
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


KINGBASE_HOME = os.environ.get("KINGBASE_HOME", "/opt/Kingbase/ES/V8/Server")
KINGBASE_BIN = os.environ.get("KINGBASE_BIN", os.path.join(KINGBASE_HOME, "bin"))
DATA_DIR = os.environ.get("KINGBASE_DATA_DIR", "/var/lib/kingbase/data")
DATA_ROOT = os.path.dirname(DATA_DIR)
HBA_FILE = os.environ.get("KINGBASE_HBA_FILE", os.path.join(DATA_DIR, "sys_hba.conf"))
PORT = os.environ.get("KINGBASE_PORT", "54321")
LOCAL_SOCKET_DIR = os.environ.get("KINGBASE_LOCAL_SOCKET_DIR", "/tmp")
DB_USER = os.environ.get("KINGBASE_SUPERUSER", "system")
DB_PASSWORD = os.environ.get("KINGBASE_PASSWORD", "")
DB_NAME = os.environ.get("KINGBASE_DATABASE", "kingbase")
REPL_USER = os.environ.get("KINGBASE_REPLICATION_USER", "replication")
REPL_PASSWORD = os.environ.get("KINGBASE_REPLICATION_PASSWORD", "")
REPL_SSLMODE = os.environ.get("KINGBASE_REPLICATION_SSLMODE", "verify-ca")
TLS_ENABLED = os.environ.get("KINGBASE_TLS_ENABLED", "0").lower() in ("1", "true", "yes", "on")
TLS_CA_FILE = os.environ.get("KINGBASE_TLS_CA_FILE", os.path.join(DATA_ROOT, "tls", "ca.crt"))
KSQL_BIN = os.environ.get("KINGBASE_KSQL_BIN", os.path.join(KINGBASE_BIN, "ksql"))
SYS_CTL_BIN = os.environ.get("KINGBASE_SYS_CTL_BIN", os.path.join(KINGBASE_BIN, "sys_ctl"))
ENCPWD_BIN = os.environ.get("KINGBASE_ENCPWD_BIN", os.path.join(KINGBASE_BIN, "sys_encpwd"))
KINGBASE_USER_HOME = os.environ.get("KINGBASE_USER_HOME", "/home/kingbase")
POD_NAME = os.environ.get("POD_NAME", "")
NAMESPACE = os.environ.get("POD_NAMESPACE", "default")

LEASE_NAME = os.environ.get("KINGBASE_HA_LEASE_NAME", "kingbase-primary")
LEASE_DURATION = int(os.environ.get("KINGBASE_HA_LEASE_DURATION_SECONDS", "30"))
BOOTSTRAP_LEASE_DURATION = int(
    os.environ.get("KINGBASE_HA_BOOTSTRAP_LEASE_DURATION_SECONDS", str(max(LEASE_DURATION * 10, 300)))
)
FENCE_TIMEOUT = int(os.environ.get("KINGBASE_HA_FENCE_TIMEOUT_SECONDS", "15"))
RETRY_PERIOD = int(os.environ.get("KINGBASE_HA_RETRY_PERIOD_SECONDS", "2"))
OBSERVATION_PUBLISH_INTERVAL = int(
    os.environ.get("KINGBASE_HA_OBSERVATION_PUBLISH_INTERVAL_SECONDS", str(max(RETRY_PERIOD * 5, 10)))
)
PROMOTE_TIMEOUT = int(os.environ.get("KINGBASE_HA_PROMOTE_TIMEOUT_SECONDS", "60"))
SWITCHOVER_CATCHUP_TIMEOUT = int(os.environ.get("KINGBASE_HA_SWITCHOVER_CATCHUP_TIMEOUT_SECONDS", "60"))
KUBE_API_TIMEOUT = int(os.environ.get("KINGBASE_HA_KUBE_API_TIMEOUT_SECONDS", "5"))
OBSERVATION_TTL = int(os.environ.get("KINGBASE_HA_OBSERVATION_TTL_SECONDS", str(max(LEASE_DURATION * 2, 60))))
FAILOVER_ENABLED = os.environ.get("KINGBASE_HA_FAILOVER_ENABLED", "0").lower() in ("1", "true", "yes", "on")
CHECK_TIMELINE = os.environ.get("KINGBASE_HA_CHECK_TIMELINE", "1").lower() in ("1", "true", "yes", "on")
PATCH_POD_ROLE = os.environ.get("KINGBASE_HA_PATCH_POD_ROLE", "0").lower() in ("1", "true", "yes", "on")
ROLE_LABEL_KEY = os.environ.get("KINGBASE_HA_ROLE_LABEL_KEY", "role")
ROLE_PRIMARY = "primary"
ROLE_STANDBY = "standby"
ROLE_UNKNOWN = "unknown"
POD_LABEL_SELECTOR = os.environ.get("KINGBASE_HA_POD_LABEL_SELECTOR", "app=kingbase")
PRIMARY_HEADLESS_TEMPLATE = os.environ.get("KINGBASE_HA_PRIMARY_HEADLESS_TEMPLATE", "")
DEMOTED_MARKER = os.path.join(DATA_ROOT, "ha-demoted")
HTTP_PORT = int(os.environ.get("KINGBASE_HA_HTTP_PORT", "8008"))
API_TOKEN = os.environ.get("KINGBASE_HA_API_TOKEN", "")

RECOVERY_SQL = os.environ.get("KINGBASE_HA_RECOVERY_SQL", "select pg_is_in_recovery()")
CURRENT_LSN_SQL = os.environ.get("KINGBASE_HA_CURRENT_LSN_SQL", "select pg_current_wal_lsn()")
REPLAY_LSN_SQL = os.environ.get("KINGBASE_HA_REPLAY_LSN_SQL", "select coalesce(pg_last_wal_replay_lsn(), '0/0'::pg_lsn)")
TIMELINE_SQL = os.environ.get("KINGBASE_HA_TIMELINE_SQL", "select timeline_id from pg_control_checkpoint()")

ANN_PREFIX = "kingbase-ha.sealos.io"
ANN_LSN = f"{ANN_PREFIX}/last-wal-lsn"
ANN_TIMELINE = f"{ANN_PREFIX}/timeline-id"
ANN_OBSERVED = f"{ANN_PREFIX}/observed-at"
ANN_ROLE = f"{ANN_PREFIX}/role"
ANN_PREFERRED = f"{ANN_PREFIX}/preferred-candidate"
ANN_SWITCHOVER = f"{ANN_PREFIX}/switchover-requested-at"
ANN_BOOTSTRAP = f"{ANN_PREFIX}/bootstrap-owner"
HBA_FENCE_START = "# BEGIN kubeblocks-switchover-fence"
HBA_FENCE_END = "# END kubeblocks-switchover-fence"

KUBE_HOST = os.environ.get("KUBERNETES_SERVICE_HOST")
KUBE_PORT = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"


def env_int(name, default):
    value = os.environ.get(name, default)
    try:
        return int(value)
    except ValueError:
        return int(decimal.Decimal(value))


MAX_LAG = env_int("KINGBASE_HA_MAXIMUM_LAG_ON_FAILOVER_BYTES", "0")


def log(message):
    print(f"{datetime.datetime.now(datetime.timezone.utc).isoformat()} {message}", flush=True)


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def kube_timestamp(value=None):
    value = value or utc_now()
    return value.isoformat(timespec="microseconds").replace("+00:00", "Z")


def parse_kube_timestamp(value):
    if not value:
        return None
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def lsn_to_int(value):
    match = re.fullmatch(r"([0-9A-Fa-f]+)/([0-9A-Fa-f]+)", value or "")
    if not match:
        raise ValueError(f"invalid WAL LSN: {value!r}")
    return (int(match.group(1), 16) << 32) + int(match.group(2), 16)


class KubeClient:
    def __init__(self):
        if not KUBE_HOST:
            raise RuntimeError("KUBERNETES_SERVICE_HOST is not set")
        self.base_url = f"https://{KUBE_HOST}:{KUBE_PORT}"
        with open(TOKEN_PATH, encoding="utf-8") as token_file:
            self.token = token_file.read().strip()
        self.context = ssl.create_default_context(cafile=CA_PATH)

    def request(self, method, path, body=None, content_type="application/json"):
        data = None
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = content_type
        request = urllib.request.Request(self.base_url + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=KUBE_API_TIMEOUT) as response:
                raw = response.read()
                return response.status, json.loads(raw.decode("utf-8")) if raw else None
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace")
            if exc.code in (404, 409):
                return exc.code, json.loads(raw) if raw else None
            raise RuntimeError(f"Kubernetes API {method} {path} failed: {exc.code} {raw}") from exc

    def get_lease(self):
        status, body = self.request("GET", f"/apis/coordination.k8s.io/v1/namespaces/{NAMESPACE}/leases/{LEASE_NAME}")
        return None if status == 404 else body

    def create_lease(self, annotations, duration=None):
        now = kube_timestamp()
        duration = duration or LEASE_DURATION
        body = {
            "apiVersion": "coordination.k8s.io/v1",
            "kind": "Lease",
            "metadata": {"name": LEASE_NAME, "namespace": NAMESPACE, "annotations": annotations},
            "spec": {
                "holderIdentity": POD_NAME,
                "leaseDurationSeconds": duration,
                "acquireTime": now,
                "renewTime": now,
                "leaseTransitions": 0,
            },
        }
        status, lease = self.request("POST", f"/apis/coordination.k8s.io/v1/namespaces/{NAMESPACE}/leases", body)
        return status == 201, lease

    def update_lease(self, lease, acquire=False, annotations=None, remove_annotations=(), duration=None):
        previous_holder = lease.get("spec", {}).get("holderIdentity")
        transitions = int(lease.get("spec", {}).get("leaseTransitions") or 0)
        now = kube_timestamp()
        if previous_holder != POD_NAME:
            transitions += 1
        lease["spec"] = {
            "holderIdentity": POD_NAME,
            "leaseDurationSeconds": duration or LEASE_DURATION,
            "renewTime": now,
            "leaseTransitions": transitions,
        }
        if acquire or previous_holder != POD_NAME:
            lease["spec"]["acquireTime"] = now
        metadata_annotations = lease.setdefault("metadata", {}).setdefault("annotations", {})
        metadata_annotations.update(annotations or {})
        for key in remove_annotations:
            metadata_annotations.pop(key, None)
        status, body = self.request(
            "PUT", f"/apis/coordination.k8s.io/v1/namespaces/{NAMESPACE}/leases/{LEASE_NAME}", lease
        )
        return status == 200, body

    def release_lease(self, lease):
        transitions = int(lease.get("spec", {}).get("leaseTransitions") or 0) + 1
        lease["spec"] = {
            "holderIdentity": "",
            "leaseDurationSeconds": 1,
            "renewTime": kube_timestamp(),
            "leaseTransitions": transitions,
        }
        status, body = self.request(
            "PUT", f"/apis/coordination.k8s.io/v1/namespaces/{NAMESPACE}/leases/{LEASE_NAME}", lease
        )
        return status == 200, body

    def list_pods(self):
        path = f"/api/v1/namespaces/{NAMESPACE}/pods"
        if POD_LABEL_SELECTOR:
            path += "?labelSelector=" + urllib.parse.quote(POD_LABEL_SELECTOR, safe="")
        status, body = self.request("GET", path)
        return body.get("items", []) if status == 200 else []

    def patch_pod_annotations(self, annotations):
        patch = {"metadata": {"annotations": annotations}}
        path = f"/api/v1/namespaces/{NAMESPACE}/pods/{urllib.parse.quote(POD_NAME, safe='')}"
        self.request("PATCH", path, patch, content_type="application/merge-patch+json")

    def set_pod_role(self, role):
        if not PATCH_POD_ROLE:
            return
        patch = {"metadata": {"labels": {ROLE_LABEL_KEY: role}}}
        path = f"/api/v1/namespaces/{NAMESPACE}/pods/{urllib.parse.quote(POD_NAME, safe='')}"
        self.request("PATCH", path, patch, content_type="application/merge-patch+json")


class ManagerState:
    def __init__(self):
        now = time.monotonic()
        self.lock = threading.RLock()
        self.fence_lock = threading.Lock()
        self.last_lease_authority = now
        self.last_reconcile = now
        self.last_observation_publish = 0.0
        self.last_observation_role = ROLE_UNKNOWN
        self.local_role = ROLE_UNKNOWN
        self.promotion_in_progress = False
        self.lease_observation_key = None
        self.lease_observed_at = now
        self.fenced = False

    def record_lease_authority(self):
        self.last_lease_authority = time.monotonic()

    def record_reconcile(self):
        self.last_reconcile = time.monotonic()

    def observe_role(self, role):
        self.local_role = role

    def should_publish_observation(self, role, force=False):
        return (
            force
            or role != self.last_observation_role
            or time.monotonic() - self.last_observation_publish >= OBSERVATION_PUBLISH_INTERVAL
        )

    def record_observation_publish(self, role):
        self.last_observation_publish = time.monotonic()
        self.last_observation_role = role

    def observe_lease(self, lease):
        metadata = lease.get("metadata", {})
        spec = lease.get("spec", {})
        key = (
            metadata.get("uid", ""),
            metadata.get("resourceVersion", ""),
            spec.get("holderIdentity", ""),
            spec.get("renewTime", ""),
        )
        if key != self.lease_observation_key:
            self.lease_observation_key = key
            self.lease_observed_at = time.monotonic()

    def lease_expired(self, lease):
        self.observe_lease(lease)
        duration = int(lease.get("spec", {}).get("leaseDurationSeconds") or LEASE_DURATION)
        return time.monotonic() - self.lease_observed_at >= duration

    def should_fence(self):
        return self.local_role != ROLE_STANDBY or self.promotion_in_progress

    def healthy(self):
        return not self.fenced and time.monotonic() - self.last_reconcile <= max(RETRY_PERIOD * 3, 15)


def run(command, check=False, timeout=10, extra_env=None):
    env = os.environ.copy()
    if DB_PASSWORD:
        env["KINGBASE_PASSWORD"] = DB_PASSWORD
    env.update(extra_env or {})
    result = subprocess.run(
        command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(command)} failed: {result.stdout.strip()}")
    return result


def as_kingbase(command):
    command = [
        "env",
        f"HOME={KINGBASE_USER_HOME}",
        "USER=kingbase",
        "LOGNAME=kingbase",
    ] + command
    if os.geteuid() != 0:
        return command
    if shutil.which("setpriv"):
        return ["setpriv", "--reuid=kingbase", "--regid=kingbase", "--init-groups"] + command
    if shutil.which("runuser"):
        return ["runuser", "-u", "kingbase", "--"] + command
    raise RuntimeError("cannot lower privileges to the kingbase user")


def control_command(arguments):
    return as_kingbase([SYS_CTL_BIN] + arguments)


def database_pid():
    try:
        with open(os.path.join(DATA_DIR, "postmaster.pid"), encoding="utf-8") as source:
            pid = source.readline().strip()
        return pid if pid.isdigit() and int(pid) > 1 else ""
    except OSError:
        return ""


def process_alive(pid):
    if not pid:
        return None
    return run(as_kingbase(["kill", "-0", pid]), timeout=2).returncode == 0


def db_ready():
    result = run(
        [KSQL_BIN, "-h", LOCAL_SOCKET_DIR, "-p", PORT, "-U", DB_USER, "-d", DB_NAME, "-At", "-c", "select 1"],
        timeout=5,
    )
    return result.returncode == 0


def query_scalar(sql, timeout=10, writable_admin=False):
    result = run(
        [KSQL_BIN, "-h", LOCAL_SOCKET_DIR, "-p", PORT, "-U", DB_USER, "-d", DB_NAME, "-At", "-c", sql],
        timeout=timeout,
        extra_env={"KINGBASE_OPTIONS": "-c default_transaction_read_only=off"} if writable_admin else None,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stdout.strip())
    return result.stdout.strip()


def in_recovery():
    return query_scalar(RECOVERY_SQL).lower() in ("t", "true", "1")


def current_lsn():
    return query_scalar(CURRENT_LSN_SQL)


def replay_lsn():
    return query_scalar(REPLAY_LSN_SQL)


def timeline_id():
    return query_scalar(TIMELINE_SQL)


def psql_literal(value):
    return "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"


def observation(role=None):
    recovery = in_recovery()
    return {
        ANN_LSN: replay_lsn() if recovery else current_lsn(),
        ANN_TIMELINE: timeline_id(),
        ANN_OBSERVED: kube_timestamp(),
        ANN_ROLE: role or (ROLE_STANDBY if recovery else ROLE_PRIMARY),
    }


def pod_ready(pod):
    if pod.get("metadata", {}).get("deletionTimestamp"):
        return False
    return any(
        condition.get("type") == "Ready" and condition.get("status") == "True"
        for condition in pod.get("status", {}).get("conditions", [])
    )


def candidate_from_pod(pod):
    metadata = pod.get("metadata", {})
    annotations = metadata.get("annotations", {})
    try:
        observed = parse_kube_timestamp(annotations.get(ANN_OBSERVED))
    except (TypeError, ValueError):
        return None
    if not metadata.get("name") or not pod_ready(pod) or observed is None:
        return None
    if utc_now() - observed > datetime.timedelta(seconds=OBSERVATION_TTL):
        return None
    if annotations.get(ANN_ROLE) != ROLE_STANDBY:
        return None
    try:
        return {
            "name": metadata["name"],
            "timeline": int(annotations[ANN_TIMELINE]),
            "lsn": lsn_to_int(annotations[ANN_LSN]),
            "observed": annotations[ANN_OBSERVED],
        }
    except (KeyError, TypeError, ValueError):
        return None


def eligible_candidates(kube, exclude=()):
    excluded = set(exclude)
    return [
        candidate
        for candidate in (candidate_from_pod(pod) for pod in kube.list_pods())
        if candidate and candidate["name"] not in excluded
    ]


def choose_candidate(kube, preferred="", exclude=()):
    candidates = eligible_candidates(kube, exclude=exclude)
    if preferred:
        return next((item for item in candidates if item["name"] == preferred), None)
    return max(candidates, key=lambda item: (item["timeline"], item["lsn"], item["name"]), default=None)


def candidate_safe(lease):
    annotations = lease.get("metadata", {}).get("annotations", {})
    lease_lsn = annotations.get(ANN_LSN, "")
    lease_timeline = annotations.get(ANN_TIMELINE, "")
    if not lease_lsn:
        log("refusing failover: lease has no primary WAL LSN")
        return False
    local_timeline = int(timeline_id())
    if CHECK_TIMELINE and (not lease_timeline or local_timeline < int(lease_timeline)):
        log(f"refusing failover: local timeline {local_timeline} is behind lease timeline {lease_timeline or 'unknown'}")
        return False
    lag = max(lsn_to_int(lease_lsn) - lsn_to_int(replay_lsn()), 0)
    if lag > MAX_LAG:
        log(f"refusing failover: replay lag {lag} exceeds {MAX_LAG}")
        return False
    return True


def promote():
    run(
        control_command(["promote", "-D", DATA_DIR, "-w", "-t", str(PROMOTE_TIMEOUT)]),
        check=True,
        timeout=PROMOTE_TIMEOUT + 5,
    )


def stop_local_primary(state, reason, graceful=False):
    with state.fence_lock:
        if state.fenced:
            return
        log(f"fencing local primary: {reason}")
        os.makedirs(DATA_ROOT, exist_ok=True)
        marker_tmp = DEMOTED_MARKER + ".tmp"
        with open(marker_tmp, "w", encoding="utf-8") as marker:
            marker.write(kube_timestamp() + "\n")
        os.replace(marker_tmp, DEMOTED_MARKER)
        pid = database_pid()
        mode = "fast" if graceful else "immediate"
        try:
            result = run(
                control_command(["-D", DATA_DIR, "-m", mode, "-w", "stop"]), timeout=15 if graceful else 5
            )
        except subprocess.TimeoutExpired:
            result = None
        alive = process_alive(pid)
        if alive:
            details = "timed out" if result is None else result.stdout.strip()
            log(f"{mode} shutdown failed, escalating to process termination: {details}")
            try:
                run(as_kingbase(["kill", "-KILL", pid]), check=True, timeout=5)
                deadline = time.monotonic() + 3
                while process_alive(pid) and time.monotonic() < deadline:
                    time.sleep(0.1)
            except (OSError, ValueError, RuntimeError) as exc:
                raise RuntimeError(f"local fencing failed: {exc}") from exc
        elif alive is None and (result is None or result.returncode != 0):
            raise RuntimeError("local fencing failed and the database PID is unavailable")
        if process_alive(pid):
            raise RuntimeError("local fencing failed: database process is still running")
        state.fenced = True


def fence_if_authority_lost(state, reason):
    if not state.should_fence():
        return False
    if time.monotonic() - state.last_lease_authority < FENCE_TIMEOUT:
        return False
    stop_local_primary(state, reason)
    return True


def primary_host_for_holder(holder):
    if PRIMARY_HEADLESS_TEMPLATE and holder:
        return PRIMARY_HEADLESS_TEMPLATE.replace("$(POD_NAME)", holder)
    return os.environ.get("KINGBASE_HA_PRIMARY_HOST", "")


def current_primary_conninfo():
    try:
        return query_scalar("show primary_conninfo")
    except RuntimeError:
        return ""


def conninfo_host(conninfo):
    match = re.search(r"(?:^|\s)host=('[^']*'|\S+)", conninfo)
    if not match:
        return ""
    host = match.group(1)
    return host[1:-1] if host.startswith("'") and host.endswith("'") else host


def write_encrypted_replication_password(host):
    if not REPL_PASSWORD:
        raise RuntimeError("KINGBASE_REPLICATION_PASSWORD is required for persistent replication authentication")
    result = run(
        as_kingbase(
            [
                ENCPWD_BIN,
                "-H",
                host,
                "-P",
                PORT,
                "-D",
                "replication",
                "-U",
                REPL_USER,
                "-W",
                REPL_PASSWORD,
            ]
        ),
        timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError(f"failed to update encrypted replication credentials for {host}")


def ensure_following(holder):
    host = primary_host_for_holder(holder)
    current = current_primary_conninfo()
    if not holder or holder == POD_NAME or not host or (
        conninfo_host(current) == host and "passfile=" not in current
    ):
        return False
    write_encrypted_replication_password(host)
    desired = f"host={host} port={PORT} user={REPL_USER} application_name={POD_NAME}"
    if TLS_ENABLED:
        desired += f" sslmode={REPL_SSLMODE} sslrootcert={TLS_CA_FILE}"
    query_scalar(f"ALTER SYSTEM SET primary_conninfo = {psql_literal(desired)}")
    # KingbaseES V9 accepts the setting but only applies primary_conninfo on
    # server start. The parent entrypoint restarts this standby when requested.
    return True


def publish_observation(kube, state, role, force=False):
    if not state.should_publish_observation(role, force=force):
        return False
    try:
        kube.patch_pod_annotations(observation(role))
        state.record_observation_publish(role)
        return True
    except Exception as exc:
        log(f"failed to publish pod WAL observation: {exc}")
        return False


def promote_with_lease_renewal(kube, lease, state):
    stop_renewal = threading.Event()
    latest_lease = [lease]
    fatal_error = [None]

    def renew_while_promoting():
        while not stop_renewal.wait(RETRY_PERIOD):
            if fatal_error[0]:
                fence_if_authority_lost(state, fatal_error[0])
                continue
            try:
                updated, renewed = kube.update_lease(latest_lease[0])
                if updated:
                    latest_lease[0] = renewed
                    state.record_lease_authority()
                    state.record_reconcile()
                    continue
                current = kube.get_lease()
                if not current or current.get("spec", {}).get("holderIdentity") != POD_NAME:
                    fatal_error[0] = "write authority changed during promotion"
                else:
                    latest_lease[0] = current
            except Exception as exc:
                log(f"lease renewal during promotion failed: {exc}")
            fence_if_authority_lost(state, "lease could not be renewed during promotion")

    renewal_thread = threading.Thread(target=renew_while_promoting, daemon=True)
    renewal_thread.start()
    try:
        promote()
    finally:
        stop_renewal.set()
        renewal_thread.join(timeout=max(RETRY_PERIOD * 2, 2))

    if fatal_error[0] or time.monotonic() - state.last_lease_authority >= FENCE_TIMEOUT or state.fenced:
        stop_local_primary(state, fatal_error[0] or "write authority expired during promotion")
        raise RuntimeError(fatal_error[0] or "write authority expired during promotion")
    updated, renewed = kube.update_lease(latest_lease[0])
    if not updated:
        raise RuntimeError("failed to confirm write authority after promotion")
    state.record_lease_authority()
    return renewed


def acquire_and_promote(kube, lease, state, lease_owned=False):
    if lease_owned:
        acquired = lease
        state.promotion_in_progress = True
    else:
        preferred = lease.get("metadata", {}).get("annotations", {}).get(ANN_PREFERRED, "")
        selected = choose_candidate(kube, preferred=preferred)
        if not selected:
            log(f"no eligible {'preferred ' if preferred else ''}standby is available for failover")
            return
        if selected["name"] != POD_NAME or not candidate_safe(lease):
            return
        updated, acquired = kube.update_lease(lease, acquire=True)
        if not updated:
            return
        state.promotion_in_progress = True
        state.record_lease_authority()
    try:
        acquired = promote_with_lease_renewal(kube, acquired, state)
        promoted_observation = observation(ROLE_PRIMARY)
        updated, _ = kube.update_lease(
            acquired,
            annotations=promoted_observation,
            remove_annotations=(ANN_PREFERRED, ANN_SWITCHOVER, ANN_BOOTSTRAP),
        )
        if not updated:
            raise RuntimeError("failed to renew lease after promotion")
        state.record_lease_authority()
        kube.patch_pod_annotations(promoted_observation)
        kube.set_pod_role(ROLE_PRIMARY)
        state.observe_role(ROLE_PRIMARY)
        state.promotion_in_progress = False
        log("promotion completed and write authority renewed")
    except Exception:
        try:
            current = kube.get_lease()
            if current and current.get("spec", {}).get("holderIdentity") == POD_NAME:
                kube.release_lease(current)
        finally:
            stop_local_primary(state, "promotion did not complete safely")
        raise


def reconcile(kube, state):
    with state.lock:
        # A known primary must renew before any KSQL probe. A local KSQL timeout
        # must not consume the lease and allow a second member to promote while
        # this server can still accept writes.
        lease = kube.get_lease()
        if lease is not None:
            holder = lease.get("spec", {}).get("holderIdentity", "")
            expired = state.lease_expired(lease)
            if holder == POD_NAME and not expired and state.local_role == ROLE_PRIMARY:
                updated, lease = kube.update_lease(lease, remove_annotations=(ANN_BOOTSTRAP,))
                if not updated:
                    raise RuntimeError("lease renewal conflicted")
                state.record_lease_authority()

        if not db_ready():
            kube.set_pod_role(ROLE_UNKNOWN)
            state.record_reconcile()
            return

        recovery = in_recovery()
        local_role = ROLE_STANDBY if recovery else ROLE_PRIMARY
        state.observe_role(local_role)
        if lease is None:
            publish_observation(kube, state, local_role)
            if not recovery:
                stop_local_primary(state, "write-authority lease is missing")
            state.record_reconcile()
            return

        holder = lease.get("spec", {}).get("holderIdentity", "")
        expired = state.lease_expired(lease)
        if holder == POD_NAME and not expired:
            if recovery:
                if FAILOVER_ENABLED and candidate_safe(lease):
                    updated, renewed = kube.update_lease(lease)
                    if updated:
                        state.record_lease_authority()
                        acquire_and_promote(kube, renewed, state, lease_owned=True)
                    else:
                        kube.release_lease(lease)
                else:
                    kube.release_lease(lease)
                state.record_reconcile()
                return
            # Confirm authority before the WAL queries below.  Those KSQL calls may
            # take seconds under load, so re-confirm the lease after role detection.
            updated, renewed = kube.update_lease(lease, remove_annotations=(ANN_BOOTSTRAP,))
            if not updated:
                raise RuntimeError("lease renewal conflicted")
            state.record_lease_authority()
            primary_observation = observation(ROLE_PRIMARY)
            updated, _ = kube.update_lease(renewed, annotations=primary_observation)
            if not updated:
                raise RuntimeError("failed to publish primary WAL observation")
            state.record_lease_authority()
            publish_observation(kube, state, ROLE_PRIMARY)
            kube.set_pod_role(ROLE_PRIMARY)
            state.record_reconcile()
            return

        if not recovery:
            stop_local_primary(state, f"lease is held by {holder or 'no member'} or has expired")
            state.record_reconcile()
            return

        publish_observation(kube, state, ROLE_STANDBY)
        kube.set_pod_role(ROLE_STANDBY)
        if not expired:
            if ensure_following(holder):
                log(f"primary changed to {holder}; restarting standby to apply primary_conninfo")
                raise SystemExit(75)
            state.record_reconcile()
            return
        if FAILOVER_ENABLED:
            refreshed = kube.get_lease()
            if refreshed and state.lease_expired(refreshed):
                acquire_and_promote(kube, refreshed, state)
        state.record_reconcile()


def candidate_wal_position(kube, name):
    for pod in kube.list_pods():
        metadata = pod.get("metadata", {})
        annotations = metadata.get("annotations", {})
        if metadata.get("name") != name or not pod_ready(pod) or annotations.get(ANN_ROLE) != ROLE_STANDBY:
            continue
        try:
            return {
                "timeline": int(annotations[ANN_TIMELINE]),
                "lsn": lsn_to_int(annotations[ANN_LSN]),
                "observed": annotations[ANN_OBSERVED],
            }
        except (KeyError, TypeError, ValueError):
            return None
    return None


def configure_default_read_only(value, reload_config):
    normalized = "on" if str(value).lower() in ("on", "true", "1") else "off"
    query_scalar(f"ALTER SYSTEM SET default_transaction_read_only = '{normalized}'", writable_admin=True)
    if reload_config:
        query_scalar("SELECT pg_reload_conf()", writable_admin=True)


def configure_client_connection_fence(enabled, reload_config):
    metadata = os.stat(HBA_FILE)
    with open(HBA_FILE, encoding="utf-8") as source:
        lines = source.readlines()

    filtered = []
    inside_fence = False
    for line in lines:
        marker = line.rstrip("\r\n")
        if marker == HBA_FENCE_START:
            if inside_fence:
                raise RuntimeError("nested switchover fence block in HBA")
            inside_fence = True
            continue
        if marker == HBA_FENCE_END:
            if not inside_fence:
                raise RuntimeError("unmatched switchover fence block in HBA")
            inside_fence = False
            continue
        if not inside_fence:
            filtered.append(line)
    if inside_fence:
        raise RuntimeError("unterminated switchover fence block in HBA")

    prefix = []
    if enabled:
        replication_host = "hostssl" if TLS_ENABLED else "host"
        prefix = [
            HBA_FENCE_START + "\n",
            f"{replication_host} replication {REPL_USER} 0.0.0.0/0 md5\n",
            f"{replication_host} replication {REPL_USER} ::/0 md5\n",
            "host all all 0.0.0.0/0 reject\n",
            "host all all ::/0 reject\n",
            HBA_FENCE_END + "\n",
        ]

    temporary = HBA_FILE + ".ha-tmp"
    try:
        with open(temporary, "w", encoding="utf-8") as target:
            target.writelines(prefix + filtered)
            target.flush()
            os.fsync(target.fileno())
        os.chmod(temporary, metadata.st_mode & 0o777)
        if os.geteuid() == 0:
            os.chown(temporary, metadata.st_uid, metadata.st_gid)
        os.replace(temporary, HBA_FILE)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    if reload_config:
        query_scalar("SELECT pg_reload_conf()", writable_admin=True)


def quiesce_client_writes():
    previous = query_scalar("SHOW default_transaction_read_only")
    hba_fenced = False
    try:
        configure_default_read_only("on", reload_config=True)
        hba_fenced = True
        configure_client_connection_fence(True, reload_config=True)
        query_scalar(
            "SELECT count(*) FROM ("
            "SELECT pg_terminate_backend(pid) FROM ("
            "SELECT pid FROM pg_stat_activity "
            "WHERE pid <> pg_backend_pid() AND datname IS NOT NULL "
            f"AND usename <> {psql_literal(DB_USER)}"
            ") AS application_sessions"
            ") AS terminated_sessions",
            writable_admin=True,
        )
        query_scalar("CHECKPOINT", writable_admin=True)
    except Exception:
        if hba_fenced:
            configure_client_connection_fence(False, reload_config=False)
        configure_default_read_only(previous, reload_config=True)
        raise
    return previous


def wait_for_candidate_catchup(kube, state, lease, candidate_name, final_observation, after_observed):
    deadline = time.monotonic() + SWITCHOVER_CATCHUP_TIMEOUT
    final_timeline = int(final_observation[ANN_TIMELINE])
    final_lsn = lsn_to_int(final_observation[ANN_LSN])
    current = lease
    while True:
        position = candidate_wal_position(kube, candidate_name)
        if (
            position
            and position["observed"] != after_observed
            and position["timeline"] == final_timeline
            and position["lsn"] >= final_lsn
        ):
            return current
        if time.monotonic() >= deadline:
            raise RuntimeError(f"candidate {candidate_name} did not replay final WAL before timeout")
        time.sleep(RETRY_PERIOD)
        updated, renewed = kube.update_lease(current, annotations=final_observation)
        if not updated:
            raise RuntimeError("write authority changed while waiting for candidate catch-up")
        current = renewed
        state.record_lease_authority()
        state.record_reconcile()


def switchover(kube, state, requested_candidate):
    with state.lock:
        if not db_ready() or in_recovery():
            raise RuntimeError("this member is not a writable primary")
        lease = kube.get_lease()
        if (
            lease is None
            or lease.get("spec", {}).get("holderIdentity") != POD_NAME
            or time.monotonic() - state.last_lease_authority >= FENCE_TIMEOUT
        ):
            raise RuntimeError("this member does not hold a live write-authority lease")

        primary_observation = observation(ROLE_PRIMARY)
        publish_observation(kube, state, ROLE_PRIMARY, force=True)
        preferred = requested_candidate.strip().split(".", 1)[0] if requested_candidate else ""
        candidate = choose_candidate(kube, preferred=preferred, exclude=(POD_NAME,))
        if not candidate:
            raise RuntimeError(f"eligible standby {preferred or 'candidate'} was not found")
        if primary_observation[ANN_TIMELINE] != str(candidate["timeline"]):
            raise RuntimeError("candidate is on a different timeline")
        lag = max(lsn_to_int(primary_observation[ANN_LSN]) - candidate["lsn"], 0)
        if lag > MAX_LAG:
            raise RuntimeError(f"candidate replay lag {lag} exceeds {MAX_LAG}")

        switchover_annotations = dict(primary_observation)
        switchover_annotations[ANN_PREFERRED] = candidate["name"]
        switchover_annotations[ANN_SWITCHOVER] = kube_timestamp()
        updated, prepared = kube.update_lease(lease, annotations=switchover_annotations)
        if not updated:
            raise RuntimeError("failed to publish switchover intent")
        state.record_lease_authority()

        previous_read_only = None
        stopping = False
        try:
            previous_read_only = quiesce_client_writes()
            final_observation = observation(ROLE_PRIMARY)
            candidate_before_wait = candidate_wal_position(kube, candidate["name"])
            if not candidate_before_wait:
                raise RuntimeError(f"candidate {candidate['name']} has no current WAL observation")
            final_observation[ANN_PREFERRED] = candidate["name"]
            final_observation[ANN_SWITCHOVER] = switchover_annotations[ANN_SWITCHOVER]
            updated, prepared = kube.update_lease(prepared, annotations=final_observation)
            if not updated:
                raise RuntimeError("failed to publish final primary WAL position")
            state.record_lease_authority()
            prepared = wait_for_candidate_catchup(
                kube,
                state,
                prepared,
                candidate["name"],
                final_observation,
                candidate_before_wait["observed"],
            )
            # Persist normal settings without reloading them into the still-fenced primary.
            configure_client_connection_fence(False, reload_config=False)
            configure_default_read_only(previous_read_only, reload_config=False)
            stopping = True
            stop_local_primary(state, f"planned switchover to {candidate['name']}", graceful=True)
        except Exception:
            if previous_read_only is not None and not stopping:
                try:
                    current = kube.get_lease()
                    if (
                        current is None
                        or current.get("spec", {}).get("holderIdentity") != POD_NAME
                        or time.monotonic() - state.last_lease_authority >= FENCE_TIMEOUT
                    ):
                        raise RuntimeError("write authority cannot be confirmed after aborted switchover")
                    updated, _ = kube.update_lease(
                        current, remove_annotations=(ANN_PREFERRED, ANN_SWITCHOVER)
                    )
                    if not updated:
                        raise RuntimeError("failed to renew authority after aborted switchover")
                    state.record_lease_authority()
                    configure_client_connection_fence(False, reload_config=False)
                    configure_default_read_only(previous_read_only, reload_config=True)
                except Exception as recovery_error:
                    try:
                        # Restore files only; do not reload them into a node without authority.
                        configure_client_connection_fence(False, reload_config=False)
                        configure_default_read_only(previous_read_only, reload_config=False)
                    except Exception as cleanup_error:
                        log(f"failed to persist normal settings before fencing: {cleanup_error}")
                    stop_local_primary(
                        state, f"aborted switchover could not safely restore writes: {recovery_error}"
                    )
            raise
        released, _ = kube.release_lease(prepared)
        if not released:
            raise RuntimeError("primary stopped but lease release failed; wait for lease expiry")
        log(f"planned switchover released write authority for {candidate['name']}")
        return candidate["name"]


def detect_role(kube, state):
    if not db_ready():
        return ROLE_UNKNOWN
    if in_recovery():
        return ROLE_STANDBY
    lease = kube.get_lease()
    if (
        lease
        and lease.get("spec", {}).get("holderIdentity") == POD_NAME
        and time.monotonic() - state.last_lease_authority < FENCE_TIMEOUT
        and not state.fenced
    ):
        return ROLE_PRIMARY
    return ROLE_UNKNOWN


class Handler(http.server.BaseHTTPRequestHandler):
    kube = None
    state = None

    def reply(self, status, payload, content_type="application/json"):
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            status = 200 if self.state.healthy() else 503
            self.reply(status, b"ok" if status == 200 else b"unhealthy", "text/plain; charset=utf-8")
            return
        if self.path != "/v1.0/getrole":
            self.reply(404, {"error": "not found"})
            return
        try:
            role = detect_role(self.kube, self.state)
        except Exception as exc:
            log(f"role probe failed: {exc}")
            role = ROLE_UNKNOWN
        self.reply(200, role.encode("utf-8"), "text/plain; charset=utf-8")

    def do_POST(self):
        if self.path != "/v1.0/switchover":
            self.reply(404, {"error": "not found"})
            return
        supplied_token = self.headers.get("Authorization", "")
        if not hmac.compare_digest(supplied_token, f"Bearer {API_TOKEN}"):
            self.reply(401, {"error": "unauthorized"})
            return
        try:
            length = min(int(self.headers.get("Content-Length", "0")), 4096)
            payload = json.loads(self.rfile.read(length) or b"{}")
            candidate = switchover(self.kube, self.state, str(payload.get("candidate", "")))
            self.reply(200, {"candidate": candidate, "status": "accepted"})
        except Exception as exc:
            log(f"switchover rejected: {exc}")
            self.reply(409, {"error": str(exc)})

    def log_message(self, fmt, *args):
        return


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def start_http(kube, state):
    Handler.kube = kube
    Handler.state = state
    server_class = getattr(http.server, "ThreadingHTTPServer", ThreadingHTTPServer)
    server = server_class(("0.0.0.0", HTTP_PORT), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()


def bootstrap_acquire():
    kube = KubeClient()
    lease = kube.get_lease()
    if lease is not None:
        annotations = lease.get("metadata", {}).get("annotations", {})
        holder = lease.get("spec", {}).get("holderIdentity")
        if holder == POD_NAME and annotations.get(ANN_BOOTSTRAP) == POD_NAME:
            refreshed, _ = kube.update_lease(lease, duration=BOOTSTRAP_LEASE_DURATION)
            if refreshed:
                log("bootstrap write-authority lease refreshed after an initialization restart")
                return 0
            log("bootstrap refused: write-authority lease changed during initialization restart")
            return 1
        log("bootstrap refused: write-authority lease already exists")
        return 1
    for pod in kube.list_pods():
        metadata = pod.get("metadata", {})
        annotations = metadata.get("annotations", {})
        if metadata.get("name") != POD_NAME and annotations.get(ANN_LSN):
            log(f"bootstrap refused: member {metadata.get('name')} has existing WAL history")
            return 1
    created, _ = kube.create_lease({ANN_BOOTSTRAP: POD_NAME}, duration=BOOTSTRAP_LEASE_DURATION)
    if not created:
        log("bootstrap refused: another member won the initialization race")
        return 1
    log("bootstrap write-authority lease acquired")
    return 0


def preflight_authority():
    kube = KubeClient()
    lease = kube.get_lease()
    if lease is None or lease.get("spec", {}).get("holderIdentity") != POD_NAME:
        log("startup preflight refused: this member does not own the write-authority lease")
        return 2
    updated, _ = kube.update_lease(lease)
    if not updated:
        log("startup preflight refused: write authority changed concurrently")
        return 2
    log("startup write authority confirmed")
    return 0


def validate_configuration():
    if not POD_NAME:
        raise RuntimeError("POD_NAME is required")
    if not API_TOKEN:
        raise RuntimeError("KINGBASE_HA_API_TOKEN is required")
    if min(
        LEASE_DURATION,
        BOOTSTRAP_LEASE_DURATION,
        FENCE_TIMEOUT,
        RETRY_PERIOD,
        SWITCHOVER_CATCHUP_TIMEOUT,
        KUBE_API_TIMEOUT,
    ) <= 0:
        raise RuntimeError("HA timing values must be positive")
    if BOOTSTRAP_LEASE_DURATION < LEASE_DURATION:
        raise RuntimeError("bootstrap lease duration must not be shorter than lease duration")
    if FENCE_TIMEOUT >= LEASE_DURATION:
        raise RuntimeError("fence timeout must be shorter than lease duration")
    if KUBE_API_TIMEOUT >= FENCE_TIMEOUT:
        raise RuntimeError("Kubernetes API timeout must be shorter than fence timeout")


def main():
    validate_configuration()
    if len(sys.argv) > 1:
        if sys.argv[1] == "bootstrap-acquire":
            return bootstrap_acquire()
        if sys.argv[1] == "preflight-authority":
            return preflight_authority()
        raise RuntimeError(f"unknown command: {sys.argv[1]}")

    kube = KubeClient()
    state = ManagerState()
    start_http(kube, state)
    log(
        f"starting Kingbase HA manager for {POD_NAME}, lease={LEASE_NAME}, "
        f"leaseDuration={LEASE_DURATION}s, fenceTimeout={FENCE_TIMEOUT}s, failover={FAILOVER_ENABLED}"
    )
    while True:
        try:
            reconcile(kube, state)
        except Exception as exc:
            log(f"reconcile failed: {exc}")
            fence_if_authority_lost(state, f"lease authority could not be confirmed for {FENCE_TIMEOUT}s")
        time.sleep(RETRY_PERIOD)


if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except KeyboardInterrupt:
        sys.exit(0)
    except Exception as exc:
        log(f"fatal: {exc}")
        sys.exit(1)
