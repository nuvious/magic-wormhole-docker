#!/usr/bin/env bash
# Report the release tag the upstream submodule is pinned to, moving it to a requested
# tag first when one is given. The version alone goes to stdout so callers can capture it.
set -euo pipefail

VERSION="${1:-}"
SUBMODULE="upstream/magic-wormhole"

# Only initialize when the checkout is missing, so reporting the pin never clobbers a
# submodule someone has deliberately moved.
if [ ! -f "${SUBMODULE}/setup.py" ]; then
    git submodule update --init --quiet "${SUBMODULE}"
fi

git -C "${SUBMODULE}" fetch --tags --force --quiet origin

if [ -n "${VERSION}" ]; then
    git -C "${SUBMODULE}" checkout --quiet --detach "refs/tags/${VERSION}"
fi

actual="$(git -C "${SUBMODULE}" describe --tags --exact-match 2>/dev/null || echo "")"

if [ -z "${actual}" ]; then
    echo "${SUBMODULE} is pinned to an untagged commit; pin it to a release tag" >&2
    exit 1
fi

if [ -n "${VERSION}" ] && [ "${actual}" != "${VERSION}" ]; then
    echo "${SUBMODULE} is at ${actual}, expected ${VERSION}" >&2
    exit 1
fi

echo "${SUBMODULE} at ${actual} ($(git -C "${SUBMODULE}" rev-parse HEAD))" >&2
echo "${actual}"
