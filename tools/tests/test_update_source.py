import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[2] / ".github" / "update_source.py"


def load_module():
	spec = importlib.util.spec_from_file_location("update_source", MODULE_PATH)
	module = importlib.util.module_from_spec(spec)
	assert spec.loader is not None
	spec.loader.exec_module(module)
	return module


class UpdateSourceTests(unittest.TestCase):
	def test_build_versions_skips_releases_without_target_asset(self):
		module = load_module()
		requested_tags = []
		module.get_build = lambda _api_root, tag_name: requested_tags.append(tag_name) or "abc1234"

		versions = module.build_versions(
			"https://api.github.com/repos/example/repo",
			"Reynard.ipa",
			[
				{
					"tag_name": "v1.0.0",
					"created_at": "2026-01-01T00:00:00Z",
					"assets": [{"name": "notes.txt"}],
				},
				{
					"tag_name": "v1.1.0",
					"created_at": "2026-01-02T00:00:00Z",
					"body": "`release`",
					"assets": [
						{
							"name": "Reynard.ipa",
							"browser_download_url": "https://example.test/Reynard.ipa",
							"size": 42,
						}
					],
				},
			],
		)

		self.assertEqual(requested_tags, ["v1.1.0"])
		self.assertEqual(len(versions), 1)
		self.assertEqual(versions[0]["buildVersion"], "abc1234")
		self.assertEqual(versions[0]["localizedDescription"], "release")

	def test_gh_response_uses_timeout(self):
		module = load_module()
		calls = []

		class Response:
			def raise_for_status(self):
				return None

		def fake_get(url, headers, timeout):
			calls.append((url, headers, timeout))
			return Response()

		module.requests.get = fake_get
		module.gh_response("https://api.github.com/test")

		self.assertEqual(calls[0][0], "https://api.github.com/test")
		self.assertEqual(calls[0][2], module.REQUEST_TIMEOUT)

	def test_gh_paginated_request_follows_next_links(self):
		module = load_module()
		requested_urls = []

		class Response:
			def __init__(self, payload, next_url=None):
				self._payload = payload
				self.links = {"next": {"url": next_url}} if next_url else {}

			def json(self):
				return self._payload

		def fake_response(url):
			requested_urls.append(url)
			if url.endswith("page=1"):
				return Response([{"id": 1}], "https://api.github.com/releases?page=2")
			return Response([{"id": 2}])

		module.gh_response = fake_response
		items = module.gh_paginated_request("https://api.github.com/releases?page=1")

		self.assertEqual(requested_urls, [
			"https://api.github.com/releases?page=1",
			"https://api.github.com/releases?page=2",
		])
		self.assertEqual(items, [{"id": 1}, {"id": 2}])

	def test_validate_source_data_rejects_missing_apps(self):
		module = load_module()

		with self.assertRaisesRegex(ValueError, "non-empty apps list"):
			module.validate_source_data({})


if __name__ == "__main__":
	unittest.main()
