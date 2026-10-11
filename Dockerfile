# syntax=docker/dockerfile:1

ARG PYTHON_VERSION=3.13

FROM python:${PYTHON_VERSION}-slim-bookworm AS source

ARG WORMHOLE_VERSION
ARG STRICT_VERSION_CHECK=1

RUN test -n "${WORMHOLE_VERSION}" || { echo "WORMHOLE_VERSION build arg is required" >&2; exit 1; }

# Upstream derives its version with versioneer from git metadata, which a submodule cannot
# carry into a build context, so the tree lands in the directory name versioneer's
# parentdir_prefix fallback reads the version out of.
COPY upstream/magic-wormhole/ /src/magic-wormhole-${WORMHOLE_VERSION}/

WORKDIR /src/magic-wormhole-${WORMHOLE_VERSION}

RUN test -f setup.py || { \
        echo "upstream/magic-wormhole is empty; run scripts/sync-submodule.sh ${WORMHOLE_VERSION}" >&2; \
        exit 1; \
    } \
 && rm -f .git

# The version is taken from the directory name above, so a submodule left on the wrong
# commit would be mislabelled rather than caught; the changelog is the one version marker
# in the tree that does not come from git.
RUN news_version="$(grep -m1 -oE '^## Release [0-9]+\.[0-9]+(\.[0-9]+)?' NEWS.md | awk '{print $3}')"; \
    if [ "${STRICT_VERSION_CHECK}" = "1" ] && [ "${news_version}" != "${WORMHOLE_VERSION}" ]; then \
        echo "NEWS.md documents ${news_version:-no release} but ${WORMHOLE_VERSION} was requested;" >&2; \
        echo "the submodule is on the wrong commit, or upstream tagged ahead of its changelog" >&2; \
        echo "(build with --build-arg STRICT_VERSION_CHECK=0 to override)" >&2; \
        exit 1; \
    fi

FROM python:${PYTHON_VERSION}-slim-bookworm AS builder

ARG WORMHOLE_VERSION

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

COPY --from=source /src /src

# Building the project wheel also collects its dependency wheels, so the runtime stage
# installs with the index switched off.
RUN pip wheel --wheel-dir /wheels "/src/magic-wormhole-${WORMHOLE_VERSION}"

# A tree that fails versioneer's fallback builds as 0+unknown rather than failing outright.
RUN ls /wheels/magic_wormhole-${WORMHOLE_VERSION}-*.whl >/dev/null || { \
        echo "source build produced $(ls /wheels/magic_wormhole-* 2>/dev/null), expected ${WORMHOLE_VERSION}" >&2; \
        exit 1; \
    }

FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

ARG WORMHOLE_VERSION
ARG REVISION=1
ARG VCS_REF=unknown
ARG UPSTREAM_REF=unknown
ARG BUILD_DATE

LABEL org.opencontainers.image.title="magic-wormhole" \
      org.opencontainers.image.description="The magic-wormhole CLI, built from upstream source, packaged for one-shot docker run invocations, with tmux, screen and trickle alongside it." \
      org.opencontainers.image.version="${WORMHOLE_VERSION}-r${REVISION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/magic-wormhole/magic-wormhole" \
      org.opencontainers.image.licenses="MIT" \
      io.magic-wormhole.upstream.commit="${UPSTREAM_REF}"

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# tmux and screen let a transfer outlive the terminal that started it, and trickle caps
# the bandwidth a transfer may use; the README covers how each is reached past the entrypoint.
RUN apt-get update \
 && apt-get install -y --no-install-recommends tmux screen trickle \
 && rm -rf /var/lib/apt/lists/*

# The symlink keeps wormhole reachable from the login shell tmux opens, since /etc/profile
# replaces PATH with one that does not include the venv.
RUN --mount=from=builder,source=/wheels,target=/wheels \
    python -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-compile --no-index --find-links=/wheels \
        "magic-wormhole==${WORMHOLE_VERSION}" \
 && find /opt/venv -name '__pycache__' -type d -prune -exec rm -rf {} + \
 && ln -s /opt/venv/bin/wormhole /usr/local/bin/wormhole

# HOME is world-writable so the image still works when run under an arbitrary --user UID.
RUN useradd --uid 1000 --create-home --home-dir /home/wormhole --shell /bin/bash wormhole \
 && chmod 0777 /home/wormhole \
 && install -d -o 1000 -g 1000 /data

# tmux and screen open $SHELL, which an arbitrary --user UID has no passwd entry to supply.
ENV PATH="/opt/venv/bin:${PATH}" \
    HOME=/home/wormhole \
    SHELL=/bin/bash \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /data
USER 1000:1000

ENTRYPOINT ["wormhole"]
CMD ["--help"]
