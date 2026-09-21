import datetime
import importlib.util
import os
import pathlib
import tempfile
import time
import unittest
from unittest import mock


os.environ.setdefault("POD_NAME", "kingbase-prod-kingbase-1")
MODULE_PATH = pathlib.Path(__file__).parents[1] / "kingbase-ha-manager.py"
SPEC = importlib.util.spec_from_file_location("kingbase_ha_manager", MODULE_PATH)
ha = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ha)


def pod(name, lsn, timeline=1, role="standby", age_seconds=0, ready=True):
    observed = ha.utc_now() - datetime.timedelta(seconds=age_seconds)
    return {
        "metadata": {
            "name": name,
            "annotations": {
                ha.ANN_LSN: lsn,
                ha.ANN_TIMELINE: str(timeline),
                ha.ANN_OBSERVED: ha.kube_timestamp(observed),
                ha.ANN_ROLE: role,
            },
        },
        "status": {"conditions": [{"type": "Ready", "status": "True" if ready else "False"}]},
    }


def lease(holder="old-primary", age_seconds=ha.LEASE_DURATION + 1):
    renewed = ha.utc_now() - datetime.timedelta(seconds=age_seconds)
    return {
        "metadata": {
            "resourceVersion": "1",
            "annotations": {ha.ANN_LSN: "0/200", ha.ANN_TIMELINE: "1"},
        },
        "spec": {
            "holderIdentity": holder,
            "leaseDurationSeconds": ha.LEASE_DURATION,
            "renewTime": ha.kube_timestamp(renewed),
        },
    }


class FakeKube:
    def __init__(self, pods=None, current_lease=None):
        self.pods = pods or []
        self.current_lease = current_lease
        self.update_calls = 0
        self.released = False
        self.created_duration = None

    def list_pods(self):
        return self.pods

    def get_lease(self):
        return self.current_lease

    def update_lease(self, current, acquire=False, annotations=None, remove_annotations=(), duration=None):
        self.update_calls += 1
        self.updated_duration = duration
        current["spec"]["holderIdentity"] = ha.POD_NAME
        self.current_lease = current
        return True, current

    def release_lease(self, current):
        self.released = True
        return True, current

    def create_lease(self, annotations, duration=None):
        self.created_duration = duration
        self.current_lease = {
            "metadata": {"annotations": annotations},
            "spec": {"holderIdentity": ha.POD_NAME, "leaseDurationSeconds": duration},
        }
        return True, self.current_lease

    def patch_pod_annotations(self, annotations):
        return None

    def set_pod_role(self, role):
        return None


class ManagerTests(unittest.TestCase):
    def test_manager_commands_keep_the_system_password(self):
        completed = mock.Mock(returncode=0)
        with (
            mock.patch.object(ha, "DB_PASSWORD", "system-marker"),
            mock.patch.object(ha.subprocess, "run", return_value=completed) as command,
        ):
            ha.run(["command"])

        self.assertEqual(command.call_args.kwargs["env"]["KINGBASE_PASSWORD"], "system-marker")

    def test_as_kingbase_uses_kingbase_home_for_persistent_credentials(self):
        with (
            mock.patch.object(ha.os, "geteuid", return_value=0),
            mock.patch.object(ha.shutil, "which", side_effect=lambda name: "/usr/bin/setpriv" if name == "setpriv" else None),
        ):
            self.assertEqual(
                ha.as_kingbase(["command"]),
                [
                    "setpriv",
                    "--reuid=kingbase",
                    "--regid=kingbase",
                    "--init-groups",
                    "env",
                    "HOME=/home/kingbase",
                    "USER=kingbase",
                    "LOGNAME=kingbase",
                    "command",
                ],
            )

    def test_lsn_conversion_is_monotonic(self):
        self.assertEqual(ha.lsn_to_int("1/0"), 1 << 32)
        self.assertGreater(ha.lsn_to_int("1/1"), ha.lsn_to_int("0/FFFFFFFF"))
        with self.assertRaises(ValueError):
            ha.lsn_to_int("not-an-lsn")

    def test_pod_observation_updates_are_throttled_without_role_change(self):
        kube = FakeKube()
        state = ha.ManagerState()
        state.record_observation_publish(ha.ROLE_STANDBY)

        with (
            mock.patch.object(ha, "observation", return_value={ha.ANN_ROLE: ha.ROLE_STANDBY}),
            mock.patch.object(kube, "patch_pod_annotations") as patch_annotations,
        ):
            self.assertFalse(ha.publish_observation(kube, state, ha.ROLE_STANDBY))
            patch_annotations.assert_not_called()

            state.last_observation_publish -= ha.OBSERVATION_PUBLISH_INTERVAL
            self.assertTrue(ha.publish_observation(kube, state, ha.ROLE_STANDBY))
            patch_annotations.assert_called_once()

    def test_pod_observation_role_change_bypasses_throttle(self):
        kube = FakeKube()
        state = ha.ManagerState()
        state.record_observation_publish(ha.ROLE_STANDBY)

        with (
            mock.patch.object(ha, "observation", return_value={ha.ANN_ROLE: ha.ROLE_PRIMARY}),
            mock.patch.object(kube, "patch_pod_annotations") as patch_annotations,
        ):
            self.assertTrue(ha.publish_observation(kube, state, ha.ROLE_PRIMARY))
            patch_annotations.assert_called_once()

    def test_candidate_selection_uses_timeline_then_lsn(self):
        kube = FakeKube(
            [
                pod("standby-a", "0/300", timeline=1),
                pod(ha.POD_NAME, "0/100", timeline=2),
                pod("standby-stale", "0/999", timeline=9, age_seconds=ha.OBSERVATION_TTL + 1),
            ]
        )
        self.assertEqual(ha.choose_candidate(kube)["name"], ha.POD_NAME)
        self.assertEqual(ha.choose_candidate(kube, preferred="standby-a")["name"], "standby-a")
        self.assertIsNone(ha.choose_candidate(kube, preferred="standby-stale"))

    def test_malformed_candidate_observation_is_ignored(self):
        malformed = pod("broken", "0/999")
        malformed["metadata"]["annotations"][ha.ANN_OBSERVED] = "not-a-time"
        self.assertIsNone(ha.candidate_from_pod(malformed))

    def test_lease_expiration_uses_local_monotonic_observation(self):
        state = ha.ManagerState()
        remote_old_lease = lease(age_seconds=ha.LEASE_DURATION * 10)
        self.assertFalse(state.lease_expired(remote_old_lease))
        state.lease_observed_at -= ha.LEASE_DURATION + 1
        self.assertTrue(state.lease_expired(remote_old_lease))

    def test_missing_lease_fences_a_local_primary_immediately(self):
        kube = FakeKube(current_lease=None)
        state = ha.ManagerState()
        with (
            mock.patch.object(ha, "db_ready", return_value=True),
            mock.patch.object(ha, "in_recovery", return_value=False),
            mock.patch.object(ha, "publish_observation"),
            mock.patch.object(ha, "stop_local_primary") as stop,
        ):
            ha.reconcile(kube, state)
        stop.assert_called_once()

    def test_known_primary_renews_lease_before_any_ksql_probe(self):
        owned = lease(holder=ha.POD_NAME, age_seconds=1)
        kube = FakeKube(current_lease=owned)
        state = ha.ManagerState()
        state.observe_role(ha.ROLE_PRIMARY)
        events = []
        original_update = kube.update_lease
        primary_observation = {
            ha.ANN_LSN: "0/200",
            ha.ANN_TIMELINE: "1",
            ha.ANN_OBSERVED: ha.kube_timestamp(),
            ha.ANN_ROLE: ha.ROLE_PRIMARY,
        }

        def renew(*args, **kwargs):
            events.append("renew")
            return original_update(*args, **kwargs)

        def collect_observation(role):
            events.append("observation")
            self.assertEqual(role, ha.ROLE_PRIMARY)
            return primary_observation

        kube.update_lease = renew
        with (
            mock.patch.object(ha, "db_ready", side_effect=lambda: events.append("db_ready") or True),
            mock.patch.object(ha, "in_recovery", side_effect=lambda: events.append("in_recovery") or False),
            mock.patch.object(ha, "observation", side_effect=collect_observation),
            mock.patch.object(ha, "publish_observation"),
        ):
            ha.reconcile(kube, state)

        self.assertEqual(events, ["renew", "db_ready", "in_recovery", "renew", "observation", "renew"])
        self.assertEqual(kube.update_calls, 3)
        self.assertGreater(state.last_lease_authority, 0)

    def test_known_primary_does_not_probe_database_when_initial_lease_renewal_conflicts(self):
        owned = lease(holder=ha.POD_NAME, age_seconds=1)
        kube = FakeKube(current_lease=owned)
        state = ha.ManagerState()
        state.observe_role(ha.ROLE_PRIMARY)

        with (
            mock.patch.object(kube, "update_lease", return_value=(False, owned)),
            mock.patch.object(ha, "db_ready") as db_ready,
            mock.patch.object(ha, "in_recovery") as in_recovery,
        ):
            with self.assertRaisesRegex(RuntimeError, "lease renewal conflicted"):
                ha.reconcile(kube, state)

        db_ready.assert_not_called()
        in_recovery.assert_not_called()

    def test_only_best_candidate_acquires_expired_lease(self):
        expired = lease()
        kube = FakeKube(
            [pod(ha.POD_NAME, "0/200"), pod("standby-best", "0/201")],
            current_lease=expired,
        )
        with mock.patch.object(ha, "candidate_safe", return_value=True):
            ha.acquire_and_promote(kube, expired, ha.ManagerState())
        self.assertEqual(kube.update_calls, 0)

    def test_owned_lease_resumes_interrupted_promotion(self):
        owned = lease(holder=ha.POD_NAME, age_seconds=1)
        kube = FakeKube(current_lease=owned)
        state = ha.ManagerState()
        with (
            mock.patch.object(ha, "candidate_safe", return_value=True),
            mock.patch.object(ha, "promote") as promote,
            mock.patch.object(
                ha,
                "observation",
                return_value={ha.ANN_LSN: "0/200", ha.ANN_TIMELINE: "2", ha.ANN_OBSERVED: ha.kube_timestamp()},
            ),
        ):
            ha.acquire_and_promote(kube, owned, state, lease_owned=True)
        promote.assert_called_once()
        self.assertEqual(kube.update_calls, 2)

    def test_lease_is_renewed_while_promotion_is_blocked(self):
        owned = lease(holder=ha.POD_NAME, age_seconds=1)
        kube = FakeKube(current_lease=owned)
        state = ha.ManagerState()
        with (
            mock.patch.object(ha, "RETRY_PERIOD", 0.01),
            mock.patch.object(ha, "promote", side_effect=lambda: time.sleep(0.04)),
        ):
            ha.promote_with_lease_renewal(kube, owned, state)
        self.assertGreaterEqual(kube.update_calls, 2)

    def test_bootstrap_owner_can_refresh_expired_lease_before_start(self):
        expired = lease(holder=ha.POD_NAME)
        expired["metadata"]["annotations"][ha.ANN_BOOTSTRAP] = ha.POD_NAME
        kube = FakeKube(current_lease=expired)
        with mock.patch.object(ha, "KubeClient", return_value=kube):
            self.assertEqual(ha.preflight_authority(), 0)
        self.assertEqual(kube.update_calls, 1)

    def test_preflight_refuses_lease_owned_by_another_member(self):
        foreign = lease(holder="different-member")
        kube = FakeKube(current_lease=foreign)
        with mock.patch.object(ha, "KubeClient", return_value=kube):
            self.assertEqual(ha.preflight_authority(), 2)
        self.assertEqual(kube.update_calls, 0)

    def test_bootstrap_lease_has_initialization_headroom(self):
        kube = FakeKube()
        with mock.patch.object(ha, "KubeClient", return_value=kube):
            self.assertEqual(ha.bootstrap_acquire(), 0)
        self.assertEqual(kube.created_duration, ha.BOOTSTRAP_LEASE_DURATION)
        self.assertGreaterEqual(kube.created_duration, ha.LEASE_DURATION)

    def test_bootstrap_owner_can_resume_before_initialization(self):
        owned = lease(holder=ha.POD_NAME, age_seconds=1)
        owned["metadata"]["annotations"][ha.ANN_BOOTSTRAP] = ha.POD_NAME
        kube = FakeKube(current_lease=owned)
        with mock.patch.object(ha, "KubeClient", return_value=kube):
            self.assertEqual(ha.bootstrap_acquire(), 0)
        self.assertEqual(kube.update_calls, 1)
        self.assertEqual(kube.updated_duration, ha.BOOTSTRAP_LEASE_DURATION)

    def test_api_loss_fences_after_timeout(self):
        state = ha.ManagerState()
        state.observe_role(ha.ROLE_PRIMARY)
        state.last_lease_authority = time.monotonic() - ha.FENCE_TIMEOUT - 1
        with (
            mock.patch.object(ha, "db_ready", return_value=True),
            mock.patch.object(ha, "in_recovery", return_value=False),
            mock.patch.object(ha, "stop_local_primary") as stop,
        ):
            self.assertTrue(ha.fence_if_authority_lost(state, "test"))
        stop.assert_called_once_with(state, "test")

    def test_api_loss_does_not_fence_a_known_standby(self):
        state = ha.ManagerState()
        state.observe_role(ha.ROLE_STANDBY)
        state.last_lease_authority = time.monotonic() - ha.FENCE_TIMEOUT - 1
        with mock.patch.object(ha, "stop_local_primary") as stop:
            self.assertFalse(ha.fence_if_authority_lost(state, "test"))
        stop.assert_not_called()

    def test_api_loss_fences_a_standby_during_promotion(self):
        state = ha.ManagerState()
        state.observe_role(ha.ROLE_STANDBY)
        state.promotion_in_progress = True
        state.last_lease_authority = time.monotonic() - ha.FENCE_TIMEOUT - 1
        with mock.patch.object(ha, "stop_local_primary") as stop:
            self.assertTrue(ha.fence_if_authority_lost(state, "test"))
        stop.assert_called_once_with(state, "test")

    def test_switchover_waits_for_final_wal_before_stopping(self):
        owned = lease(holder=ha.POD_NAME, age_seconds=1)
        kube = FakeKube(pods=[pod("standby-a", "0/300")], current_lease=owned)
        state = ha.ManagerState()
        state.observe_role(ha.ROLE_PRIMARY)
        primary_observation = {
            ha.ANN_LSN: "0/200",
            ha.ANN_TIMELINE: "1",
            ha.ANN_OBSERVED: ha.kube_timestamp(),
            ha.ANN_ROLE: ha.ROLE_PRIMARY,
        }
        candidate_observations = [
            {"timeline": 1, "lsn": ha.lsn_to_int("0/200"), "observed": "before"},
            {"timeline": 1, "lsn": ha.lsn_to_int("0/300"), "observed": "after"},
        ]
        with (
            mock.patch.object(ha, "db_ready", return_value=True),
            mock.patch.object(ha, "in_recovery", return_value=False),
            mock.patch.object(ha, "observation", return_value=primary_observation),
            mock.patch.object(ha, "publish_observation"),
            mock.patch.object(ha, "quiesce_client_writes", return_value="off"),
            mock.patch.object(ha, "candidate_wal_position", side_effect=candidate_observations),
            mock.patch.object(ha, "configure_client_connection_fence") as hba_fence,
            mock.patch.object(ha, "configure_default_read_only") as configure,
            mock.patch.object(ha, "stop_local_primary") as stop,
        ):
            selected = ha.switchover(kube, state, "standby-a")
        self.assertEqual(selected, "standby-a")
        self.assertTrue(kube.released)
        self.assertEqual(kube.update_calls, 2)
        hba_fence.assert_called_once_with(False, reload_config=False)
        configure.assert_called_once_with("off", reload_config=False)
        stop.assert_called_once()

    def test_aborted_switchover_restores_write_mode(self):
        owned = lease(holder=ha.POD_NAME, age_seconds=1)
        kube = FakeKube(pods=[pod("standby-a", "0/300")], current_lease=owned)
        state = ha.ManagerState()
        state.observe_role(ha.ROLE_PRIMARY)
        primary_observation = {
            ha.ANN_LSN: "0/200",
            ha.ANN_TIMELINE: "1",
            ha.ANN_OBSERVED: ha.kube_timestamp(),
            ha.ANN_ROLE: ha.ROLE_PRIMARY,
        }
        with (
            mock.patch.object(ha, "db_ready", return_value=True),
            mock.patch.object(ha, "in_recovery", return_value=False),
            mock.patch.object(ha, "observation", return_value=primary_observation),
            mock.patch.object(ha, "publish_observation"),
            mock.patch.object(ha, "quiesce_client_writes", return_value="off"),
            mock.patch.object(
                ha,
                "candidate_wal_position",
                return_value={"timeline": 1, "lsn": ha.lsn_to_int("0/200"), "observed": "before"},
            ),
            mock.patch.object(ha, "wait_for_candidate_catchup", side_effect=RuntimeError("timeout")),
            mock.patch.object(ha, "configure_client_connection_fence") as hba_fence,
            mock.patch.object(ha, "configure_default_read_only") as configure,
            mock.patch.object(ha, "stop_local_primary") as stop,
        ):
            with self.assertRaisesRegex(RuntimeError, "timeout"):
                ha.switchover(kube, state, "standby-a")
        configure.assert_called_once_with("off", reload_config=True)
        hba_fence.assert_called_once_with(False, reload_config=False)
        stop.assert_not_called()
        self.assertFalse(kube.released)

    def test_aborted_switchover_fences_if_lease_owner_changed(self):
        owned = lease(holder=ha.POD_NAME, age_seconds=1)
        kube = FakeKube(pods=[pod("standby-a", "0/300")], current_lease=owned)
        state = ha.ManagerState()
        state.observe_role(ha.ROLE_PRIMARY)
        primary_observation = {
            ha.ANN_LSN: "0/200",
            ha.ANN_TIMELINE: "1",
            ha.ANN_OBSERVED: ha.kube_timestamp(),
            ha.ANN_ROLE: ha.ROLE_PRIMARY,
        }

        def lose_authority(*args, **kwargs):
            kube.current_lease["spec"]["holderIdentity"] = "new-primary"
            raise RuntimeError("lease conflict")

        with (
            mock.patch.object(ha, "db_ready", return_value=True),
            mock.patch.object(ha, "in_recovery", return_value=False),
            mock.patch.object(ha, "observation", return_value=primary_observation),
            mock.patch.object(ha, "publish_observation"),
            mock.patch.object(ha, "quiesce_client_writes", return_value="off"),
            mock.patch.object(
                ha,
                "candidate_wal_position",
                return_value={"timeline": 1, "lsn": ha.lsn_to_int("0/200"), "observed": "before"},
            ),
            mock.patch.object(ha, "wait_for_candidate_catchup", side_effect=lose_authority),
            mock.patch.object(ha, "configure_client_connection_fence") as hba_fence,
            mock.patch.object(ha, "configure_default_read_only") as configure,
            mock.patch.object(ha, "stop_local_primary") as stop,
        ):
            with self.assertRaisesRegex(RuntimeError, "lease conflict"):
                ha.switchover(kube, state, "standby-a")
        configure.assert_called_once_with("off", reload_config=False)
        hba_fence.assert_called_once_with(False, reload_config=False)
        stop.assert_called_once()

    def test_candidate_catchup_requires_a_new_observation(self):
        owned = lease(holder=ha.POD_NAME, age_seconds=1)
        kube = FakeKube(current_lease=owned)
        state = ha.ManagerState()
        final_observation = {ha.ANN_LSN: "0/200", ha.ANN_TIMELINE: "1"}
        positions = [
            {"timeline": 1, "lsn": ha.lsn_to_int("0/300"), "observed": "before"},
            {"timeline": 1, "lsn": ha.lsn_to_int("0/300"), "observed": "after"},
        ]
        with (
            mock.patch.object(ha, "RETRY_PERIOD", 0),
            mock.patch.object(ha, "candidate_wal_position", side_effect=positions),
        ):
            result = ha.wait_for_candidate_catchup(
                kube, state, owned, "standby-a", final_observation, "before"
            )
        self.assertIs(result, owned)
        self.assertEqual(kube.update_calls, 1)

    def test_hba_connection_fence_is_reversible(self):
        original = "host all all 0.0.0.0/0 md5\n"
        with tempfile.TemporaryDirectory() as directory:
            hba_path = pathlib.Path(directory) / "sys_hba.conf"
            hba_path.write_text(original, encoding="utf-8")
            with (
                mock.patch.object(ha, "HBA_FILE", str(hba_path)),
                mock.patch.object(ha, "TLS_ENABLED", False),
            ):
                ha.configure_client_connection_fence(True, reload_config=False)
                fenced = hba_path.read_text(encoding="utf-8")
                self.assertIn("host all all 0.0.0.0/0 reject", fenced)
                self.assertNotIn("host all all 127.0.0.1/32 md5", fenced)
                self.assertIn(f"host replication {ha.REPL_USER} 0.0.0.0/0 md5", fenced)
                ha.configure_client_connection_fence(False, reload_config=False)
            self.assertEqual(hba_path.read_text(encoding="utf-8"), original)

    def test_write_quiesce_preserves_system_management_connections(self):
        sql = []
        with (
            mock.patch.object(ha, "query_scalar", side_effect=lambda statement, **_: sql.append(statement) or "off"),
            mock.patch.object(ha, "configure_default_read_only"),
            mock.patch.object(ha, "configure_client_connection_fence"),
        ):
            ha.quiesce_client_writes()

        terminate_statement = next(statement for statement in sql if "pg_terminate_backend" in statement)
        self.assertIn(f"usename <> {ha.psql_literal(ha.DB_USER)}", terminate_statement)
        self.assertIn("SELECT pg_terminate_backend(pid) FROM (SELECT pid FROM pg_stat_activity", terminate_statement)

    def test_following_conninfo_uses_encrypted_password_store_and_tls(self):
        sql = []
        with (
            mock.patch.object(ha, "PRIMARY_HEADLESS_TEMPLATE", "$(POD_NAME).headless.svc"),
            mock.patch.object(ha, "TLS_ENABLED", True),
            mock.patch.object(ha, "current_primary_conninfo", return_value="host=old-primary"),
            mock.patch.object(ha, "write_encrypted_replication_password") as write_password,
            mock.patch.object(ha, "query_scalar", side_effect=lambda statement: sql.append(statement) or ""),
        ):
            changed = ha.ensure_following("new-primary")
        self.assertTrue(changed)
        write_password.assert_called_once_with("new-primary.headless.svc")
        self.assertNotIn("passfile=", sql[0])
        self.assertIn(f"sslmode={ha.REPL_SSLMODE}", sql[0])
        self.assertIn("host=new-primary.headless.svc", sql[0])
        self.assertEqual(len(sql), 1)

    def test_reconcile_restarts_only_standby_after_primary_change(self):
        current_lease = lease(holder="new-primary", age_seconds=1)
        kube = FakeKube(current_lease=current_lease)
        state = ha.ManagerState()
        with (
            mock.patch.object(ha, "db_ready", return_value=True),
            mock.patch.object(ha, "in_recovery", return_value=True),
            mock.patch.object(ha, "publish_observation"),
            mock.patch.object(ha, "ensure_following", return_value=True),
        ):
            with self.assertRaises(SystemExit) as exited:
                ha.reconcile(kube, state)

        self.assertEqual(exited.exception.code, 75)


if __name__ == "__main__":
    unittest.main()
