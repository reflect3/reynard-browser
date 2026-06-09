import json
import os
from pathlib import Path
import requests

REQUEST_TIMEOUT = (5, 30)


def gh_headers() -> dict[str, str]:
	headers = {
		"Accept": "application/vnd.github+json",
		"X-GitHub-Api-Version": "2026-03-10",
	}

	token = os.environ.get("GITHUB_TOKEN")
	if token:
		headers["Authorization"] = f"Bearer {token}"

	return headers


def gh_response(url: str):
	try:
		response = requests.get(url, headers=gh_headers(), timeout=REQUEST_TIMEOUT)
		response.raise_for_status()
	except Exception as error:
		print(f"GitHub request failed for {url}: {error}")
		raise

	return response


def gh_request(url: str):
	return gh_response(url).json()


def gh_paginated_request(url: str) -> list[dict]:
	items = []
	next_url: str | None = url

	while next_url:
		response = gh_response(next_url)
		payload = response.json()
		if not isinstance(payload, list):
			raise ValueError(f"GitHub paginated response must be a list for {next_url}")

		items.extend(payload)
		next_url = response.links.get("next", {}).get("url")

	return items

def get_build(api_root: str, tag_name: str) -> str:
	ref = gh_request(f"{api_root}/git/ref/tags/{tag_name}")
	target = ref["object"]

	if target["type"] == "tag":
		target = gh_request(target["url"])["object"]

	return target["sha"][:7]

def build_versions(api_root: str, asset_name: str, releases: list[dict]) -> list[dict]:
	versions = []

	for release in releases:
		asset = next(
			(asset for asset in release.get("assets", []) if asset.get("name") == asset_name),
			None,
		)
		if asset is None:
			continue

		build_version = get_build(api_root, release["tag_name"])
		versions.append(
			{
				"version": release["tag_name"],
				"buildVersion": build_version,
				"date": release["created_at"],
				"localizedDescription": (release.get("body") or "").replace("`", ""),
				"downloadURL": asset["browser_download_url"],
				"size": asset["size"],
			}
		)

	return versions


def validate_source_data(source_data: dict) -> None:
	apps = source_data.get("apps")
	if not isinstance(apps, list) or not apps:
		raise ValueError("source.json must contain a non-empty apps list")

	if not isinstance(apps[0], dict):
		raise ValueError("source.json apps[0] must be an object")

def main() -> None:
	api_root = "https://api.github.com/repos/minh-ton/reynard-browser"
	source_path = Path(__file__).with_name("source.json")
	asset_name = "Reynard.ipa"

	source_data = json.loads(source_path.read_text(encoding="utf-8"))
	validate_source_data(source_data)
	releases = gh_paginated_request(f"{api_root}/releases?per_page=100")
	source_data["apps"][0]["versions"] = build_versions(api_root, asset_name, releases)

	output = json.dumps(source_data, indent=2)
	json.loads(output)
	source_path.write_text(output, encoding="utf-8")

if __name__ == "__main__":
	main()
