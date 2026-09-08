#!/usr/bin/env python3
"""Decide which upstream magic-wormhole version to build and what to tag it."""

import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request

SEMVER = re.compile(r"^v?(\d+)\.(\d+)(?:\.(\d+))?$")


def get_json(url, headers=None):
    request = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def upstream_versions(repo, token):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "magic-wormhole-docker"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    versions = []
    for page in range(1, 6):
        url = f"https://api.github.com/repos/{repo}/tags?per_page=100&page={page}"
        tags = get_json(url, headers)
        if not tags:
            break
        for tag in tags:
            match = SEMVER.match(tag["name"])
            if match:
                versions.append(tag["name"].lstrip("v"))
    return versions


def sort_key(version):
    parts = version.split(".")
    return tuple(int(part) for part in (parts + ["0", "0", "0"])[:3])


def published_tags(image, token):
    """List tags already in the registry, treating any failure as an empty registry."""
    repository = image.split("/", 1)[1] if image.startswith("ghcr.io/") else image
    attempts = []
    if token:
        encoded = base64.b64encode(token.encode()).decode()
        attempts.append({"Authorization": f"Bearer {encoded}"})
    try:
        anonymous = get_json(
            f"https://ghcr.io/token?service=ghcr.io&scope=repository:{repository}:pull"
        )
        attempts.append({"Authorization": f"Bearer {anonymous['token']}"})
    except (urllib.error.URLError, OSError, KeyError, ValueError):
        pass
    for headers in attempts:
        try:
            body = get_json(f"https://ghcr.io/v2/{repository}/tags/list?n=1000", headers)
            return body.get("tags") or []
        except (urllib.error.URLError, OSError, ValueError):
            continue
    return []


def next_revision(version, tags):
    pattern = re.compile(rf"^{re.escape(version)}-r(\d+)$")
    revisions = [int(m.group(1)) for m in (pattern.match(tag) for tag in tags) if m]
    return max(revisions, default=0) + 1


def emit(outputs):
    for key, value in outputs.items():
        print(f"{key}={value}")
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            for key, value in outputs.items():
                handle.write(f"{key}={value}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="magic-wormhole/magic-wormhole")
    parser.add_argument("--image", required=True)
    parser.add_argument("--version", default="", help="build this version instead of the latest tag")
    parser.add_argument("--force", action="store_true", help="rebuild even if already published")
    args = parser.parse_args()

    token = os.environ.get("GITHUB_TOKEN", "")

    versions = upstream_versions(args.repo, token)
    if not versions:
        print(f"no semver tags found on {args.repo}", file=sys.stderr)
        return 1
    newest = max(versions, key=sort_key)
    version = args.version.lstrip("v") if args.version else newest

    # A backfill of an older release must not drag the latest tag backwards.
    is_latest = sort_key(version) >= sort_key(newest)

    tags = published_tags(args.image, token)
    already_published = version in tags
    revision = next_revision(version, tags)

    if not already_published:
        should_build, reason = True, f"{version} is not published yet"
    elif args.force:
        should_build, reason = True, f"forced rebuild of {version} as revision {revision}"
    else:
        should_build, reason = False, f"{version} is already published and no rebuild was requested"

    major_minor = ".".join(version.split(".")[:2])
    image_tags = [f"{args.image}:{version}-r{revision}", f"{args.image}:{version}", f"{args.image}:{major_minor}"]
    if is_latest:
        image_tags.append(f"{args.image}:latest")

    emit(
        {
            "version": version,
            "revision": revision,
            "should_build": str(should_build).lower(),
            "reason": reason,
            "tags": ",".join(image_tags),
        }
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
