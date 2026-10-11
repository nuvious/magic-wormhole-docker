# magic-wormhole-docker

The [magic-wormhole](https://github.com/magic-wormhole/magic-wormhole) CLI in a
container, so you can move a file between two machines without putting a Python
toolchain on either of them. The image carries the `wormhole` client and
nothing else, it is built from upstream source rather than from a package
index, and its version tags track the upstream repository's git tags.

Upstream is a git submodule at `upstream/magic-wormhole`, pinned to the release
tag the published image was built from, so the commit that produced any given
tag is recorded in this repository rather than inferred from a version string.

```
ghcr.io/nuvious/magic-wormhole:latest
```

## Included Tools

The image carries a few tools besides the `wormhole` client, all installed from
the Debian package index at build time.

- `wormhole`, the magic-wormhole CLI and the image's entrypoint.
- `screen`, a terminal multiplexer for sessions that outlive your connection.
- `tmux`, a second terminal multiplexer, for those who prefer it.
- `trickle`, a userspace bandwidth shaper for capping a transfer's rate.

The entrypoint stays `wormhole`, so reach any of the others by overriding it
with `--entrypoint`, for example `--entrypoint tmux`. For a session that
survives a dropped terminal, run the multiplexer detached as the container's
main process and attach to it with `docker exec`:

```bash
$> docker run -d --name wh -v "$(pwd):/data" --entrypoint tmux \
    ghcr.io/nuvious/magic-wormhole:latest new-session -s main
$> docker exec -it wh tmux attach -t main # Detach with Ctrl-b d; the container keeps running.
```

## Sending a File

The entrypoint is `wormhole` itself, so everything after the image name is
passed straight through to it. Mount the directory holding the file at `/data`
and run as yourself, so that anything you receive lands owned by you rather
than by the container user.

```bash
$> docker run --rm -it --user "$(id -u):$(id -g)" -v "$(pwd):/data" \
    ghcr.io/nuvious/magic-wormhole:latest send report.txt
Sending 51 Byte file named 'report.txt'
Wormhole code is: 14-unravel-deadbolt # Read this to the other machine.
On the other computer, please run:
wormhole receive 14-unravel-deadbolt
Sending (->relay:tcp:transit.magic-wormhole.io:4001)..
100%|##########| 51.0/51.0 [00:00<00:00, 138kB/s]
Confirmation received. Transfer complete.
```

On the receiving machine, mount the directory you want the file written into:

```bash
$> docker run --rm -it --user "$(id -u):$(id -g)" -v "$(pwd):/data" \
    ghcr.io/nuvious/magic-wormhole:latest receive 14-unravel-deadbolt
Receiving file (51 Bytes) into: 'report.txt'
ok? (y/N): y
Receiving (->relay:tcp:transit.magic-wormhole.io:4001)..
100%|##########| 51.0/51.0 [00:00<00:00, 291kB/s]
Received file written to: /data/report.txt # Owned by you, not by root.
```

**NOTE:** `-it` matters. Both `send` and `receive` prompt interactively, and
without a TTY the code entry and the `ok? (y/N)` confirmation have nowhere to
go. `send` also prints the code as an ASCII QR block ahead of the text above,
which is fine on a terminal and unhelpful in a log; `--no-qr`, or
`WORMHOLE_QR=0` in the environment, turns it off.

### Throttling a Transfer

`trickle` caps the bandwidth of whatever it launches by intercepting its
socket calls, and rates are given in KB/s. The `-s` flag runs it standalone,
which is the only mode that makes sense in a container since there is no
`trickled` daemon to coordinate with. This limits a `send` to 100 KB/s upload:

```bash
$> docker run --rm -it --user "$(id -u):$(id -g)" -v "$(pwd):/data" \
    --entrypoint trickle ghcr.io/nuvious/magic-wormhole:latest \
    -s -u 100 wormhole send report.txt
```

Use `-d` for a download cap on the `receive` side. **NOTE:** the limit applies
to the process that trickle launched, so it only shapes the side of the
transfer you run it on, and the other machine is free to go as fast as the link
allows.

## Wrapper Script

`bin/wormhole` wraps that invocation so the command reads like the native one.
Put it somewhere on your `PATH` and the two commands above collapse to:

```bash
$> wormhole send report.txt
$> wormhole receive 14-unravel-deadbolt
```

It mounts the current working directory, which means relative paths work and
paths outside that directory do not. Set `WORMHOLE_IMAGE` to pin a version
instead of tracking `latest`. There is a `docker-compose.yml` doing the same
thing if you would rather run it under compose, where the equivalent is
`docker compose run --rm wormhole send report.txt`. Compose reads the UID and
GID from the environment and neither shell exports them by default, so
`export UID GID` first if yours are not 1000.

## Tags

Tags follow the upstream release they were built from, plus a build revision so
that a rebuild against a patched base image is addressable without inventing a
version upstream never published.

|Tag|Meaning|
|-|-|
|`0.24.0-r1`|Upstream 0.24.0, first build of this image. Immutable.|
|`0.24.0`|The newest revision built from upstream 0.24.0.|
|`0.24`|The newest patch release in the 0.24 line.|
|`latest`|The newest upstream release.|

Pin the `-rN` form in anything that needs to be reproducible; the other three
move under you by design.

## How the Automation Works

Upstream publishes git tags but no GitHub Release objects, and a workflow here
could not subscribe to another repository's events in any case, so the "new
upstream release" trigger is a poll rather than a hook. The `publish` workflow
runs every six hours, asks the GitHub tags API for the newest semver tag on
`magic-wormhole/magic-wormhole`, and compares it against the tags already in
the registry. If that version is not published yet it moves the submodule onto
the tag, builds `linux/amd64` and `linux/arm64` from that source, checks that
`wormhole --version` inside the resulting image reports the version it asked
for, pushes, and then commits the submodule bump to `main` so the pin on record
is the one that actually shipped. The upstream commit is also stamped onto the
image as the `io.magic-wormhole.upstream.commit` label.

Nothing is built when there is nothing new. A push to `main` touching the
Dockerfile or the scripts, or a manual run with `force` checked, rebuilds the
current version at the next revision, and `workflow_dispatch` also takes an
explicit `version` if you need to backfill an older release. The submodule pin
itself is not in the `push` path filter, so the bump commit does not retrigger
the workflow.

**NOTE:** GitHub disables scheduled workflows in a repository with no commit
activity for 60 days. The bump commits count, but they only land when upstream
releases, and upstream can easily go quiet for longer than that, so this is not
a guarantee. If the poll stops firing, that is why, and re-enabling it from the
Actions tab is the fix.

## Building From Source

The build is three stages on `python:3.13-slim-bookworm`. A `source` stage
stages the submodule tree and sanity-checks it, a `builder` stage compiles the
project wheel and collects every dependency wheel, and the runtime stage
installs those into a venv with the package index switched off. Nothing from
the first two stages survives into the published image, so it carries no build
tooling, no source tree, and no git.

```bash
$> git clone --recurse-submodules https://github.com/nuvious/magic-wormhole-docker
$> cd magic-wormhole-docker
$> scripts/sync-submodule.sh 0.24.0 # Omit the version to build the pinned one.
upstream/magic-wormhole at 0.24.0 (3bf46e020341ff966aa1ca58d7260005256c1a8f)
$> docker build --build-arg WORMHOLE_VERSION=0.24.0 -t magic-wormhole:0.24.0 .
$> docker run --rm magic-wormhole:0.24.0 --version
magic-wormhole 0.24.0
```

If you cloned without `--recurse-submodules` the source tree is empty and the
build fails in the first stage telling you to run the sync script.
`WORMHOLE_VERSION` is required, so an unpinned build is rejected rather than
producing something whose provenance is a guess.

### Where the Version Comes From

Upstream derives its version with versioneer, which reads `git describe` at
build time. A submodule's `.git` is a file pointing back into the superproject,
so it does not resolve inside a container and versioneer would report
`0+unknown`. The `source` stage therefore uses versioneer's own
`parentdir_prefix` fallback, the one written for sdists, by placing the tree in
a directory named `magic-wormhole-<version>`.

That fallback takes the version from a directory name we choose, which means a
submodule left on the wrong commit would be silently mislabelled rather than
caught. Two things close that gap. `scripts/sync-submodule.sh` refuses to
report a version unless the submodule is on an exact tag, and the `source`
stage cross-checks the requested version against the first release heading in
the submodule's `NEWS.md`, which is the one version marker in the tree that
does not come from git.

```bash
$> docker build --build-arg WORMHOLE_VERSION=0.23.0 . # Submodule is on 0.24.0.
NEWS.md documents 0.24.0 but 0.23.0 was requested;
the submodule is on the wrong commit, or upstream tagged ahead of its changelog
(build with --build-arg STRICT_VERSION_CHECK=0 to override)
```

**NOTE:** that check assumes upstream updates the changelog before tagging,
which is how the releases so far have been cut. If they ever tag first the
build fails rather than mislabelling, and the escape hatch is the
`strict_version_check` input on a manual `publish` run.

## License

MIT, matching upstream. This repository packages magic-wormhole and is not
affiliated with the project.
