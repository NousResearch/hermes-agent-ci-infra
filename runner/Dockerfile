FROM ghcr.io/falcondev-oss/actions-runner:latest

USER root

# System deps that ubuntu-latest has but the runner image doesn't.
# These fix the failures we saw in the draft PR CI run:
#   - shellcheck: docker-lint workflow (exit 127)
#   - build-essential: npm ci failing (native module compilation)
#   - jq: js-tests workspace discovery
#   - gh: GitHub API/Actions commands used by CI jobs
#   - man-db + manpages: command grammar exercised by approval-parser tests
#   - zstd: faster cache compression (recommended by cache server docs)
#   - python3-dev + python3-venv: node-gyp needs python3 headers
#   - python-is-python3: compatibility with tools that invoke `python`
#   - xvfb + Electron libraries: desktop Playwright E2E on ARC
RUN apt-get update && apt-get install -y --no-install-recommends \
    shellcheck \
    build-essential \
    jq \
    gh \
    man-db \
    manpages \
    zstd \
    python3-dev \
    python3-venv \
    python-is-python3 \
    xvfb \
    libgtk-3-0 \
    libnotify4 \
    libnss3 \
    libxss1 \
    libxtst6 \
    xdg-utils \
    libatspi2.0-0 \
    libdrm2 \
    libgbm1 \
    libasound2t64 \
    && rm -rf /var/lib/apt/lists/*

# The base runner image excludes manual pages. Restore them before installing
# man-db so parser integration tests run against the same man implementation
# and page set as GitHub's Ubuntu runners.
RUN sed -i '/^path-exclude=\/usr\/share\/man\/\*/d' /etc/dpkg/dpkg.cfg.d/excludes \
    # The base image's diversion points at a stripped target, so remove its
    # metadata without renaming before the man-db reinstall restores /usr/bin/man.
    && dpkg-divert --quiet --remove --no-rename /usr/bin/man \
    && apt-get update \
    && apt-get install --reinstall -y --no-install-recommends coreutils man-db manpages \
    && rm -f /etc/update-motd.d/60-unminimize \
    && rm -rf /var/lib/apt/lists/*

# Equivalent to `loginctl enable-linger runner`. Docker builds do not have a
# running systemd login manager, so create the persistent marker it reads.
RUN install -d -m 0755 /var/lib/systemd/linger \
    && touch /var/lib/systemd/linger/runner

USER runner
