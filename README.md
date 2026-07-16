# GitHub Actions Runner Container

Docker container for automated GitHub Actions self-hosted runners.

Inspired from https://github.com/chaddyc/gha-runner and tweaked for my personal needs

## Authentication: REGISTRATION_TOKEN vs GITHUB_PAT

The container needs exactly **one** of these two, never both:

- **`REGISTRATION_TOKEN`** — a one-time token you copy manually from
  `Settings > Actions > Runners > New self-hosted runner`. It expires after 1 hour.
  Fine for a single manual run, painful for a long-lived/persistent runner (e.g. on a
  VPS): every restart after the token expires needs a fresh manual token, and if the
  container has been running for a while, the *same* stale token is reused to
  deregister the runner on shutdown, which fails and leaves it listed as "offline" in
  GitHub.
- **`GITHUB_PAT`** — a token with **Administration: Read & write** permission on the
  repo (fine-grained PAT scoped to just this one repo, not the whole org, is strongly
  recommended). The container uses it to mint a **fresh** registration token on
  startup and a **fresh** removal token on shutdown, automatically, via the GitHub
  API. This is the recommended mode for a persistent runner (VPS/EasyPanel-style
  deployment) since it never needs manual token renewal.
  **Note the blast radius**: `Administration: Read & write` also allows deleting the
  repo, managing webhooks, and branch protections — treat this PAT like a secret with
  real admin power, not a throwaway credential. The container never exposes it (or
  the tokens it fetches) to the jobs it runs — both are scrubbed from the process
  environment right after registration, before the runner starts accepting jobs.

## Required Environment Variables

````dotenv
# GitHub repository URL
REPO_URL=https://github.com/owner/repo

# Exactly one of the two:
REGISTRATION_TOKEN=<your-registration-token>
# GITHUB_PAT=<fine-grained-PAT-with-Administration:Read&write-on-this-repo>

# OPTIONAL Runner name (default: docker-runner-{hostname})
RUNNER_NAME=<your-runner-name>

# OPTIONAL Additional comma-separated runner labels
# Default labels are always included: docker,linux,ubuntu-{version},runner-{version}
RUNNER_LABELS=<label1,label2>

# OPTIONAL Run in ephemeral mode (default: false)
# https://docs.github.com/pt/actions/reference/runners/self-hosted-runners#ephemeral-runners-for-autoscaling
EPHEMERAL=false

# OPTIONAL Disable automatic runner software updates (default: true)
# The image is rebuilt daily with the latest runner version via CI, so runtime
# self-update is disabled by default to keep the running version traceable to the
# image tag. Set to false to let the runner update itself at runtime instead.
# https://docs.github.com/pt/actions/reference/runners/self-hosted-runners#runner-software-updates-on-self-hosted-runners
DISABLE_UPDATE=true

````

## Volumes

For persistent logs and runner data between container restarts:

- **`/runner/_work`** - Job execution logs and temporary files
- **`/opt/hostedtoolcache`** - Tool cache for faster job execution (optional)

## Docker Socket Access

The container does not modify `/var/run/docker.sock` permissions or its own group
membership at runtime (no `chmod 666`, no `sudo`, no dynamic `groupmod`/`usermod`
inside the container). Instead, grant the container the host socket's group via
Docker's own `--group-add` (or `group_add` in Compose), which is the safe, standard
way to do this:

```bash
# Find the docker.sock group ID on the host
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)

docker run -d \
  ... \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --group-add "$DOCKER_GID" \
  --privileged \
  multileaf/gh-runner:latest-x64
```

If you skip this, any step in a job that calls the Docker CLI will fail with a clear
"permission denied" error against the socket — nothing silently falls back to a
looser permission mode.

## Signal Handling

The image runs [`tini`](https://github.com/krallin/tini) as PID 1 (`ENTRYPOINT
["/usr/bin/tini", "--", "/runner/entrypoint.sh"]`), so it reaps zombie processes
correctly and delivers signals to `entrypoint.sh` the way a normal init process
would. On `docker stop` (SIGTERM) or Ctrl-C (SIGINT), `entrypoint.sh` forwards the
signal to the runner process and waits for it to actually finish its own graceful
job-cancellation/shutdown before deregistering — it does not exit immediately and
leave the runner orphaned mid-shutdown.

This graceful shutdown can take longer than Docker's 10s default grace period,
especially with a job in progress plus the 1-2 GitHub API calls needed to fetch a
fresh removal token. Give it more time or it gets SIGKILLed mid-shutdown, which
leaves the runner registered as "offline" instead of properly deregistered:
`docker-compose.yml` already sets `stop_grace_period: 60s`; for plain `docker run`,
stop the container with `docker stop -t 60 <container>` (or pass `--stop-timeout 60`
at `docker run` time).

## Resource Limits

`docker-compose.yml` caps each replica's CPU, memory, and process count, configurable
via `RUNNER_CPU_LIMIT` (default `2`), `RUNNER_MEMORY_LIMIT` (default `4G`), and
`RUNNER_PIDS_LIMIT` (default `512`).

**What this does and doesn't protect against**: these limits bound the runner process
itself (git, npm, build toolchains running directly inside the container) against
accidental runaway resource use. They do **not** sandbox `docker build`/`docker run`
invoked by a job — those run as sibling containers on the host's `dockerd` via the
mounted socket, entirely outside this container's cgroup, so they aren't capped by
these settings. Combined with `--privileged`, this means resource limits are not an
adversarial security boundary against a malicious job — only protection against
accidental exhaustion (a runaway `npm install`, an unbounded build cache, etc.).

If a job hits the memory limit, the kernel OOM-killer sends `SIGKILL` to the offending
process — this shows up as an unexplained `exit code 137` in job logs, not a clear
"out of memory" error. If you see that, raise `RUNNER_MEMORY_LIMIT` or investigate the
job's actual memory use before assuming it's a bug in the job itself.

## Playwright / E2E Tests

Jobs run as the non-root `runner` user with no `sudo`, so anything that needs
`apt` (system-level dependencies) can't be installed from a job step. This is
relevant for E2E testing with [Playwright](https://playwright.dev), which needs
**two** things:

- **Browser binaries** (Chromium) — downloaded per-job by `npx playwright install`
  to the runner user's cache (`~/.cache/ms-playwright`). No root needed; each
  project pins its own Playwright/browser version, so nothing is baked in.
- **Chromium system libraries** (`libnss3`, `libgbm1`, `libatk`, `libasound2`,
  ...) — installed via `apt` and therefore **preinstalled in the image at build
  time** with `npx playwright install-deps chromium`.

So a Playwright job only needs `npx playwright install` (binaries); the OS
libraries are already present. The package list tracks Playwright's own installer
(`latest`) rather than a hand-maintained list, and since system deps are
stable/cumulative, the superset covers older Playwright versions too. The daily
CI rebuild keeps it current.

## Supply Chain

- **Runner tarball integrity**: the build verifies the downloaded
  `actions-runner-linux-*.tar.gz` against the SHA-256 digest GitHub publishes for that
  asset via its Releases API (`digest` field, a different origin than the download
  itself), failing the build on any mismatch. This catches corruption/tampering on the
  download path; it doesn't protect against a compromised release at the source, which
  would require manually pinning known-good hashes instead of always tracking the
  latest release automatically.
- **SBOM & provenance**: published images include an SBOM and build provenance
  attestation (via `docker buildx`'s native support), inspectable with
  `docker buildx imagetools inspect --format '{{ json .SBOM }}' multileaf/gh-runner:latest-x64`.
- **Signed images**: images are signed keylessly with [cosign](https://github.com/sigstore/cosign)
  via GitHub Actions' own OIDC identity (no private keys to manage or leak). Verify an
  image before running it, especially on a persistent VPS deployment, with:
  ```bash
  cosign verify \
    --certificate-identity-regexp "^https://github.com/MultiLeaf/gha-runner/.github/workflows/" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    multileaf/gh-runner@<digest>
  ```
- **Vulnerability scanning**: every build is scanned with [Trivy](https://github.com/aquasecurity/trivy)
  *before* it's published — results are visible in the repo's Security tab, and the
  build only fails (blocking the push) on CRITICAL vulnerabilities that have a fix
  available. Ubuntu/Docker-Engine-based images realistically never reach zero
  findings across all severities, so blocking on everything would just leave the
  pipeline permanently red without adding real protection.

## Usage

### Using Pre-built Images

The project automatically builds and publishes images to **Docker Hub**: `multileaf/gh-runner`

### Available Tags

- `latest-x64` / `latest-arm64` - Latest runner version for each architecture.
  **Floating**: rebuilt daily to pick up OS security patches, so the content behind
  this tag changes over time even though the tag name doesn't.
- `{version}-x64` / `{version}-arm64` - Specific runner version (e.g., `2.311.0-x64`).
  Also floating for the same reason — as long as this is the latest runner release,
  the daily rebuild keeps republishing under this same tag with updated OS packages.

For a truly immutable reference, pin by digest instead of tag (each build's summary
prints the digest) — and verify it with `cosign` first (see [Supply Chain](#supply-chain)),
since pinning an unverified digest doesn't guarantee anything on its own:
```bash
docker pull multileaf/gh-runner@sha256:<digest>
```

The examples below use `REGISTRATION_TOKEN`; replace `-e REGISTRATION_TOKEN=...` with
`-e GITHUB_PAT=...` for a persistent deployment that doesn't need manual token
renewal (see [Authentication](#authentication-registration_token-vs-github_pat)).

```bash
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)

# x64 architecture
docker run -d \
  -e REPO_URL=https://github.com/owner/repo \
  -e REGISTRATION_TOKEN=your_token_here \
  -e RUNNER_NAME=my-runner \
  -e RUNNER_LABELS=docker,linux,custom \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v runner_work:/runner/_work \
  -v runner_toolcache:/opt/hostedtoolcache \
  --group-add "$DOCKER_GID" \
  --privileged \
  multileaf/gh-runner:latest-x64

# ARM64 architecture
docker run -d \
  -e REPO_URL=https://github.com/owner/repo \
  -e REGISTRATION_TOKEN=your_token_here \
  -e RUNNER_NAME=my-runner \
  -e RUNNER_LABELS=docker,linux,custom \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v runner_work:/runner/_work \
  -v runner_toolcache:/opt/hostedtoolcache \
  --group-add "$DOCKER_GID" \
  --privileged \
  multileaf/gh-runner:latest-arm64
```

### Using Docker Compose

1. Create a `.env` file with your configuration:
```bash
REPO_URL=https://github.com/owner/repo
REGISTRATION_TOKEN=your_token_here
# Or, for a persistent deployment (recommended, no manual token renewal):
# GITHUB_PAT=your_fine_grained_pat_here
RUNNER_NAME=my-docker-runner
RUNNER_LABELS=docker,linux,custom
EPHEMERAL=false
# Required for Docker-in-Docker access. Get the value by running on the host:
#   stat -c '%g' /var/run/docker.sock
DOCKER_GID=<paste-the-gid-here>
# OPTIONAL Per-replica resource limits (defaults: 2 CPUs, 4G memory, 512 pids)
# See "Resource Limits" for what these do and don't protect against.
RUNNER_CPU_LIMIT=2
RUNNER_MEMORY_LIMIT=4G
RUNNER_PIDS_LIMIT=512
```

2. Start the runner:
```bash
docker-compose up -d
```

3. Check logs:
```bash
docker-compose logs -f github-runner
```

4. Stop the runner:
```bash
docker-compose down
```

The Docker Compose configuration includes persistent volumes for logs and tool cache, ensuring data persistence across container restarts.

#### Scaling Runners

To run multiple runner instances (useful for handling multiple parallel jobs):

```bash
# Scale to 5 runners
docker-compose up -d --scale github-runner=5

# Or modify docker-compose.yml to set default replicas
# deploy:
#   replicas: 3
```

Each runner instance will have a unique name with the container hostname appended (e.g., `my-runner-abc123`, `my-runner-def456`), preventing naming conflicts.

Each replica gets its own [resource limits](#resource-limits), so total consumption
scales linearly: with the defaults (2 CPU / 4G memory each), 5 replicas can use up to
10 CPUs and 20G of memory if all are busy at once. Size `RUNNER_CPU_LIMIT`/
`RUNNER_MEMORY_LIMIT` and the replica count to what your VPS actually has available.

### Building the image:
```bash
# Build with default version (2.335.1)
docker build -t github-runner .

# Build with specific version
docker build --build-arg RUNNER_VERSION=2.335.1 -t github-runner .
```

## Included Features

- Ubuntu 24.04 base
- Docker-in-Docker support
- Node.js LTS
- Python 3
- Git
- Essential build tools
- Chromium system libraries for Playwright preinstalled (see [Playwright / E2E Tests](#playwright--e2e-tests))
- Automatic runner cleanup on container stop, with graceful shutdown via `tini` +
  signal forwarding to the runner process
- Optional GitHub PAT-based authentication for persistent deployments (no manual
  token renewal)
- Runtime self-update disabled by default (`DISABLE_UPDATE=true`) — the image is
  rebuilt daily with the latest runner version via CI, keeping the running version
  traceable to the image tag
- Configurable runner version via build argument
- Multi-architecture support (x64/ARM64)
- Ephemeral mode support - runs only one job and removes itself automatically
- Pre-configured toolcache directory with proper permissions
