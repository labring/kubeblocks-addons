import pathlib
import unittest


ACTIONSET_PATH = pathlib.Path(__file__).parents[2] / "templates" / "actionset.yaml"


class RestoreActionSetTests(unittest.TestCase):
    def test_restore_preserves_strict_data_directory_permissions(self):
        template = ACTIONSET_PATH.read_text()

        expected_steps = [
            'data_root="$(dirname "$DATA_DIR")"',
            'chown kingbase:kingbase "$data_root"',
            'chmod 2770 "$data_root"',
            'chmod 0700 "$DATA_DIR"',
            'chmod g-s "$DATA_DIR"',
        ]
        positions = [template.index(step) for step in expected_steps]

        self.assertEqual(positions, sorted(positions))
