import pathlib
import unittest


PREFLIGHT_PATH = pathlib.Path(__file__).parents[2] / "scripts" / "preflight-kb08.sh"


class PreflightScriptTests(unittest.TestCase):
    def test_required_secret_keys_are_checked_without_decoding_them(self):
        script = PREFLIGHT_PATH.read_text()

        expected_checks = [
            'check_secret_key "$license_secret" "license.dat"',
            'check_secret_key "$tls_secret" "tls.crt"',
            'check_secret_key "$tls_secret" "tls.key"',
            'check_secret_key "$tls_secret" "ca.crt"',
            'check_secret_key "$ha_token_secret" "token"',
        ]

        for check in expected_checks:
            self.assertIn(check, script)
        self.assertNotIn("base64 --decode", script)
