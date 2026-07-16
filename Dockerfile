ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

ARG RUNNER_VERSION=2.335.1
ARG RUNNER_SHA256=""
ARG TARGETARCH
ARG GIT_SHA=""

LABEL org.opencontainers.image.source="https://github.com/MultiLeaf/gha-runner"
LABEL org.opencontainers.image.description="GitHub Actions Self-Hosted Runner Container"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.version="${RUNNER_VERSION}"
LABEL org.opencontainers.image.revision="${GIT_SHA}"

ENV DEBIAN_FRONTEND=noninteractive
ENV AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y \
    curl \
    wget \
    unzip \
    git \
    jq \
    build-essential \
    libssl-dev \
    libffi-dev \
    python3 \
    python3-pip \
    python3-dev \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    tar \
    nano \
    tini \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://get.docker.com -o get-docker.sh && \
    sh get-docker.sh && \
    rm get-docker.sh

RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs

# Chromium system libraries required by Playwright for E2E tests. Job steps run
# as the non-root `runner` user (no sudo), so anything needing apt must be baked
# into the image at build time. Only OS libs are installed here; the browser
# binaries are downloaded per-job (npx playwright install) so each project pins
# its own Playwright version. Using `latest` keeps the broadest superset of libs:
# system deps are stable/cumulative, so they cover older Playwright versions too.
# `install-deps` is idempotent and the image is rebuilt daily by CI.
RUN npx --yes playwright install-deps chromium \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /runner

RUN if [ "${TARGETARCH}" = "amd64" ]; then \
      export RUNNER_ARCH="x64"; \
    elif [ "${TARGETARCH}" = "arm64" ]; then \
      export RUNNER_ARCH="arm64"; \
    else \
      echo "Unsupported architecture: ${TARGETARCH}"; exit 1; \
    fi && \
    TARBALL="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" && \
    curl -fo "$TARBALL" -L "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}" && \
    EXPECTED_SHA256="${RUNNER_SHA256}" && \
    if [ -z "$EXPECTED_SHA256" ]; then \
      echo "RUNNER_SHA256 not provided, fetching digest from GitHub API..." && \
      EXPECTED_SHA256=$(curl -fsSL "https://api.github.com/repos/actions/runner/releases/tags/v${RUNNER_VERSION}" \
        | jq -r --arg name "$TARBALL" '.assets[] | select(.name == $name) | .digest' \
        | sed 's/^sha256://'); \
    fi && \
    if [ -z "$EXPECTED_SHA256" ] || [ "$EXPECTED_SHA256" = "null" ]; then \
      echo "Error: could not determine expected SHA256 for $TARBALL"; exit 1; \
    fi && \
    echo "${EXPECTED_SHA256}  ${TARBALL}" | sha256sum -c - && \
    tar xzf "$TARBALL" && \
    rm "$TARBALL" && \
    echo "Runner version: ${RUNNER_ARCH}-${RUNNER_VERSION} (sha256 verified: ${EXPECTED_SHA256})"

RUN ./bin/installdependencies.sh

RUN useradd -m -s /bin/bash runner
RUN chown -R runner:runner /runner

RUN mkdir -p /opt/hostedtoolcache
RUN chown -R runner:runner /opt/hostedtoolcache

COPY entrypoint.sh /runner/entrypoint.sh
RUN chmod +x /runner/entrypoint.sh
RUN chown runner:runner /runner/entrypoint.sh

USER runner

ENTRYPOINT ["/usr/bin/tini", "--", "/runner/entrypoint.sh"]
