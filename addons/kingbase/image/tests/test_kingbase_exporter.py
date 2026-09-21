import importlib.util
import pathlib
import unittest
from unittest import mock


MODULE_PATH = pathlib.Path(__file__).parents[1] / "kingbase-exporter.py"
SPEC = importlib.util.spec_from_file_location("kingbase_exporter", MODULE_PATH)
exporter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(exporter)


class ExporterTests(unittest.TestCase):
    def test_database_failure_emits_one_down_sample(self):
        with mock.patch.object(exporter, "query", side_effect=RuntimeError("down")):
            output = exporter.metrics().decode("utf-8")
        samples = [line for line in output.splitlines() if line.startswith("kingbase_up{")]
        self.assertEqual(len(samples), 1)
        self.assertTrue(samples[0].endswith(" 0"))

    def test_optional_metric_failure_does_not_mark_database_down(self):
        with mock.patch.object(exporter, "query", side_effect=[["f"], RuntimeError("unsupported"), RuntimeError("unsupported")]):
            output = exporter.metrics().decode("utf-8")
        samples = [line for line in output.splitlines() if line.startswith("kingbase_up{")]
        self.assertEqual(len(samples), 1)
        self.assertTrue(samples[0].endswith(" 1"))


if __name__ == "__main__":
    unittest.main()
