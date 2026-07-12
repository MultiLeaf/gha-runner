#!/bin/bash

echo "Starting..."

set -e

if [ -z "$REPO_URL" ]; then
    echo "Error: REPO_URL environment variable is required"
    echo "Example: https://github.com/owner/repo"
    exit 1
fi

if [ -n "$REGISTRATION_TOKEN" ] && [ -n "$GITHUB_PAT" ]; then
    echo "Error: set only one of REGISTRATION_TOKEN or GITHUB_PAT, not both"
    exit 1
fi

if [ -z "$REGISTRATION_TOKEN" ] && [ -z "$GITHUB_PAT" ]; then
    echo "Error: either REGISTRATION_TOKEN or GITHUB_PAT environment variable is required"
    echo "REGISTRATION_TOKEN: one-time token from \$REPO_URL/settings/actions/runners/new"
    echo "GITHUB_PAT: a token with 'Administration: Read & write' permission on the repo,"
    echo "used to mint fresh registration/removal tokens automatically"
    exit 1
fi

OWNER_REPO=$(echo "$REPO_URL" | sed -E 's#^https?://github\.com/##; s#[?#].*$##; s#/+$##; s#\.git$##; s#/+$##')

if [ -n "$GITHUB_PAT" ] && ! echo "$OWNER_REPO" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
    echo "Error: could not parse owner/repo from REPO_URL='$REPO_URL' (expected https://github.com/owner/repo)"
    exit 1
fi

github_api_token() {
    # $1: PAT, $2: "registration-token" or "remove-token"
    local pat="$1" kind="$2" response
    if ! response=$(curl -sf --max-time 15 --connect-timeout 5 -X POST \
        -H "Authorization: Bearer $pat" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${OWNER_REPO}/actions/runners/${kind}"); then
        return 1
    fi
    echo "$response" | jq -r '.token // empty'
}

if [ -n "$GITHUB_PAT" ]; then
    echo "Fetching registration token via GITHUB_PAT..."
    if ! REGISTRATION_TOKEN=$(github_api_token "$GITHUB_PAT" "registration-token"); then
        echo "Error: failed to obtain a registration token using GITHUB_PAT"
        echo "Check token scope/permissions (needs 'Administration: Read & write' on $OWNER_REPO) and REPO_URL"
        exit 1
    fi
    if [ -z "$REGISTRATION_TOKEN" ]; then
        echo "Error: GitHub API returned an empty registration token (check PAT permissions)"
        exit 1
    fi
fi

if [ -z "$RUNNER_NAME" ]; then
    RUNNER_NAME="docker-runner-$(hostname)"
else
    RUNNER_NAME="${RUNNER_NAME}-$(hostname)"
fi

EPHEMERAL=${EPHEMERAL:-"false"}
DISABLE_UPDATE=${DISABLE_UPDATE:-"true"}

# Get Ubuntu version
UBUNTU_VERSION=$(lsb_release -rs)

# Get runner version from the installed runner
RUNNER_VERSION=$(./bin/Runner.Listener --version | head -1 | cut -d' ' -f3)

# Build labels with version info always included
DEFAULT_LABELS="docker,ubuntu-${UBUNTU_VERSION},runner-${RUNNER_VERSION}"
USER_LABELS=${RUNNER_LABELS:-""}

if [ -n "$USER_LABELS" ]; then
    RUNNER_LABELS="${DEFAULT_LABELS},${USER_LABELS}"
else
    RUNNER_LABELS="$DEFAULT_LABELS"
fi

echo "Configuring GitHub Actions Runner..."
echo "Runner Version: $RUNNER_VERSION"
echo "Repository: $REPO_URL"
echo "Runner Name: $RUNNER_NAME"
echo "Labels: $RUNNER_LABELS"
echo "Ephemeral: $EPHEMERAL"
echo "Disable Update: $DISABLE_UPDATE"

CONFIG_ARGS="--url $REPO_URL --token $REGISTRATION_TOKEN --name $RUNNER_NAME --labels $RUNNER_LABELS --work _work --unattended --replace"

if [ "$EPHEMERAL" = "true" ]; then
    CONFIG_ARGS="$CONFIG_ARGS --ephemeral"
fi

if [ "$DISABLE_UPDATE" = "true" ]; then
    CONFIG_ARGS="$CONFIG_ARGS --disableupdate"
fi

./config.sh $CONFIG_ARGS

# Keep what cleanup() needs in non-exported variables, then scrub the sensitive
# env vars so job steps (children of Runner.Listener/Runner.Worker) never inherit them.
_CLEANUP_GITHUB_PAT="$GITHUB_PAT"
_CLEANUP_REGISTRATION_TOKEN="$REGISTRATION_TOKEN"
unset GITHUB_PAT REGISTRATION_TOKEN

CLEANED_UP=0
cleanup() {
    if [ "$CLEANED_UP" -eq 1 ]; then
        return
    fi
    CLEANED_UP=1

    if [ "$EPHEMERAL" != "true" ]; then
        echo "Removing runner..."
        local remove_token

        if [ -n "$_CLEANUP_GITHUB_PAT" ]; then
            if ! remove_token=$(github_api_token "$_CLEANUP_GITHUB_PAT" "remove-token"); then
                echo "Warning: failed to obtain a fresh removal token via GITHUB_PAT; runner may remain registered as offline"
                return
            fi
            if [ -z "$remove_token" ]; then
                echo "Warning: GitHub API returned an empty removal token; runner may remain registered as offline"
                return
            fi
        else
            remove_token="$_CLEANUP_REGISTRATION_TOKEN"
        fi

        ./config.sh remove --token "$remove_token" || echo "Warning: failed to remove runner registration (token may have expired)"
    else
        echo "Ephemeral runner - no manual cleanup needed"
    fi
}

RUN_PID=""
forward_signal() {
    if [ -n "$RUN_PID" ]; then
        kill -s "$1" "$RUN_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'forward_signal TERM' TERM
trap 'forward_signal INT' INT

echo "Starting GitHub Actions Runner $RUNNER_NAME"

./run.sh &
RUN_PID=$!

# `wait` returns early (with a >128 status) the moment a trapped signal is
# caught, even though the child may still be gracefully shutting down. Loop
# until the child has actually exited so we propagate its real exit code and
# don't fire cleanup() before the runner has finished stopping.
while true; do
    # `wait` as a bare statement is subject to `set -e`; wrapping it as an
    # `if` condition exempts it so an early return doesn't abort the script
    # before we can loop back and wait for the real exit code.
    if wait "$RUN_PID"; then
        RUN_EXIT=0
    else
        RUN_EXIT=$?
    fi
    if ! kill -0 "$RUN_PID" 2>/dev/null; then
        break
    fi
done

exit "$RUN_EXIT"
