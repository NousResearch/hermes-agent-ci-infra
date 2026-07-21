FROM ghcr.io/falcondev-oss/actions-runner:latest

USER root

# System deps that ubuntu-latest has but the runner image doesn't.
# These fix the failures we saw in the draft PR CI run:
#   - shellcheck: docker-lint workflow (exit 127)
#   - build-essential: npm ci failing (native module compilation)
#   - jq: js-tests workspace discovery
#   - zstd: faster cache compression (recommended by cache server docs)
#   - python3-dev + python3-venv: node-gyp needs python3 headers
#   - python-is-python3: compatibility with tools that invoke `python`
#   - xvfb + Electron libraries: desktop Playwright E2E on ARC
RUN apt-get update && apt-get install -y --no-install-recommends \
    shellcheck \
    build-essential \
    jq \
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

USER runner
