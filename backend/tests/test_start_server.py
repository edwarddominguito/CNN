import os
import unittest
from unittest.mock import patch

from scripts import start_server


class StartupTests(unittest.TestCase):
    def test_railway_port_and_resource_limits(self):
        with patch.dict(os.environ, {"PORT": "4567"}), patch.object(start_server.uvicorn, "run") as run:
            start_server.main()
        self.assertEqual(run.call_args.args[0], "app.main:app")
        self.assertEqual(run.call_args.kwargs["host"], "0.0.0.0")
        self.assertEqual(run.call_args.kwargs["port"], 4567)
        self.assertEqual(run.call_args.kwargs["workers"], 1)
        self.assertEqual(run.call_args.kwargs["limit_concurrency"], 32)

    def test_invalid_port_fails_before_launch(self):
        for port in ("0", "65536", "invalid"):
            with self.subTest(port=port), patch.dict(os.environ, {"PORT": port}), patch.object(start_server.uvicorn, "run") as run:
                with self.assertRaises(SystemExit):
                    start_server.main()
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
