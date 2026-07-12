# GitHub Actions Runner Container

Docker container for automated GitHub Actions self-hosted runners.

Inspired from https://github.com/chaddyc/gha-runner and tweaked for my personal needs

## How to get the Registration Token

1. Access your repository on GitHub
2. Go to Settings > Actions > Runners
3. Click on "New self-hosted runner"
4. Copy the token displayed in the "Configure" section

## Required Environment Variables

````dotenv
# GitHub repository URL
REPO_URL=https://github.com/owner/repo

# Runner registration token (obtained from Settings > Actions > Runners > New runner)
REGISTRATION_TOKEN=<your-registration-token>

# OPTIONAL Runner name (default: docker-runner-{hostname})
RUNNER_NAME=<your-runner-name>

# OPTIONAL Additional comma-separated runner labels
# Default labels are always included: docker,linux,ubuntu-{version},runner-{version}
RUNNER_LABELS=<label1,label2>

# OPTIONAL Run in ephemeral mode (default: false)
# https://docs.github.com/pt/actions/reference/runners/self-hosted-runners#ephemeral-runners-for-autoscaling
EPHEMERAL=false

# OPTIONAL Disable automatic runner software updates (default: false)
# https://docs.github.com/pt/actions/reference/runners/self-hosted-runners#runner-software-updates-on-self-hosted-runners
DISABLE_UPDATE=false

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

## Usage

### Using Pre-built Images

The project automatically builds and publishes images to **Docker Hub**: `multileaf/gh-runner`

### Available Tags

- `latest-x64` / `latest-arm64` - Latest runner version for each architecture
- `{version}-x64` / `{version}-arm64` - Specific runner version (e.g., `2.311.0-x64`)

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
RUNNER_NAME=my-docker-runner
RUNNER_LABELS=docker,linux,custom
EPHEMERAL=false
# Required for Docker-in-Docker access: run `stat -c '%g' /var/run/docker.sock` on the host
DOCKER_GID=999
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

### Building the image:
```bash
# Build with default version (2.328.0)
docker build -t github-runner .

# Build with specific version
docker build --build-arg RUNNER_VERSION=2.328.0 -t github-runner .
```

## Included Features

- Ubuntu 24.04 base
- Docker-in-Docker support
- Node.js LTS
- Python 3
- Git
- Essential build tools
- Automatic runner cleanup on container stop
- Configurable runner version via build argument
- Multi-architecture support (x64/ARM64)
- Ephemeral mode support - runs only one job and removes itself automatically
- Pre-configured toolcache directory with proper permissions
