import json
import unittest
from unittest.mock import patch

from scripts import smoke_deployment as smoke


class DeploymentSmokeTests(unittest.TestCase):
    def web_response(self, base_url, path, **kwargs):
        return {
            "/": (
                200,
                {"Content-Type": "text/html; charset=utf-8"},
                b'<html><script type="module" src="/assets/app.js"></script>'
                b'<link rel="stylesheet" href="/assets/app.css"></html>',
            ),
            "/assets/app.js": (200, {"Content-Type": "text/javascript; charset=utf-8"}, b"renderApp()"),
            "/assets/app.css": (200, {"Content-Type": "text/css"}, b"body{margin:0}"),
        }.get(path, (404, {}, b""))

    def test_web_check_fetches_javascript_and_css(self):
        with patch.object(smoke, "request", side_effect=self.web_response) as request:
            smoke.check_web_client("http://example.test")
        paths = {call.args[1] for call in request.call_args_list}
        self.assertTrue({"/assets/app.js", "/assets/app.css"}.issubset(paths))

    def test_html_cannot_hide_missing_bundle_or_spa_asset_fallback(self):
        for failed_path, failed_response in (
            ("/assets/app.js", (404, {}, b"")),
            ("/assets/app.css", (200, {"Content-Type": "text/html"}, b"<html></html>")),
            ("/assets/__deployment_smoke_missing__.js", (200, {"Content-Type": "text/html"}, b"<html></html>")),
            ("/predict/__deployment_smoke_missing__", (200, {"Content-Type": "text/html"}, b"<html></html>")),
        ):
            def response(base_url, path, **kwargs):
                return failed_response if path == failed_path else self.web_response(base_url, path, **kwargs)

            with self.subTest(path=failed_path), patch.object(smoke, "request", side_effect=response):
                with self.assertRaises(RuntimeError):
                    smoke.check_web_client("http://example.test")

    def test_placeholder_html_without_javascript_is_rejected(self):
        with patch.object(smoke, "request", return_value=(200, {"Content-Type": "text/html"}, b"<html>Loading</html>")):
            with self.assertRaises(RuntimeError):
                smoke.check_web_client("http://example.test")

    def test_prediction_must_be_newly_persisted(self):
        for history_saved, newest_id, success in ((True, 2, True), (False, 2, False), (True, 1, False)):
            result = {"predicted_grade": "Premium", "confidence": 51.25, "history_saved": history_saved}
            histories = [[{"id": 1}], [{"id": newest_id, "predictedGrade": "Premium", "confidence": 51.25}]]
            with self.subTest(saved=history_saved, newest_id=newest_id), patch.object(
                smoke, "get_json", side_effect=histories
            ), patch.object(smoke, "request", return_value=(200, {}, json.dumps(result).encode())):
                if success:
                    smoke.exercise_prediction("http://example.test", ["Premium"])
                else:
                    with self.assertRaises(RuntimeError):
                        smoke.exercise_prediction("http://example.test", ["Premium"])


if __name__ == "__main__":
    unittest.main()
