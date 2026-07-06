#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETBOX_DOCKER_DIR="${NETBOX_DOCKER_DIR:-${DOCKER_DIR:-$REPO_ROOT/../netbox-docker}}"
OVERRIDE_FILE="${OVERRIDE_FILE:-$REPO_ROOT/docker/docker-compose.override.yml}"
export NETDOC_PATH="${NETDOC_PATH:-$REPO_ROOT}"
INSTALL_LOCAL_OVERRIDE="${INSTALL_LOCAL_OVERRIDE:-1}"
BRANCH="${1:-}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
NETBOX_STARTUP_TIMEOUT="${NETBOX_STARTUP_TIMEOUT:-600}"
NETBOX_WORKER_STARTUP_TIMEOUT="${NETBOX_WORKER_STARTUP_TIMEOUT:-180}"

cd "$REPO_ROOT"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
TARGET_BRANCH="${BRANCH:-$CURRENT_BRANCH}"
CURRENT_COMMIT="$(git rev-parse HEAD)"

echo "Repository: $REPO_ROOT"
echo "Branch: $TARGET_BRANCH"
echo "Current commit: $CURRENT_COMMIT"
echo "NetBox Docker directory: $NETBOX_DOCKER_DIR"
echo "Compose override: $OVERRIDE_FILE"
echo "NETDOC_PATH: $NETDOC_PATH"
echo "Install local override into netbox-docker: $INSTALL_LOCAL_OVERRIDE"
echo "NetBox startup timeout: ${NETBOX_STARTUP_TIMEOUT}s"
echo "NetBox worker startup timeout: ${NETBOX_WORKER_STARTUP_TIMEOUT}s"

if [ ! -f "$NETBOX_DOCKER_DIR/docker-compose.yml" ]; then
    echo "Could not find netbox-docker compose file at: $NETBOX_DOCKER_DIR/docker-compose.yml"
    exit 1
fi

if [ ! -f "$OVERRIDE_FILE" ]; then
    echo "Could not find NetDoc compose override at: $OVERRIDE_FILE"
    exit 1
fi

if [ "$INSTALL_LOCAL_OVERRIDE" = "1" ]; then
    LOCAL_OVERRIDE_PATH="$NETBOX_DOCKER_DIR/docker-compose.override.yml"
    ln -sfn "$OVERRIDE_FILE" "$LOCAL_OVERRIDE_PATH"
    echo "Linked compose override: $LOCAL_OVERRIDE_PATH -> $OVERRIDE_FILE"
fi

compose() {
    docker compose \
        --project-directory "$NETBOX_DOCKER_DIR" \
        -f "$NETBOX_DOCKER_DIR/docker-compose.yml" \
        -f "$OVERRIDE_FILE" \
        "$@"
}

wait_for_container_state() {
    local container_name="$1"
    local expected_state="$2"
    local timeout_seconds="${3:-120}"
    local status=""

    for _ in $(seq 1 "$timeout_seconds"); do
        status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_name" 2>/dev/null || true)"
        if [ "$status" = "$expected_state" ]; then
            return 0
        fi
        sleep 1
    done

    echo "Container $container_name did not reach state '$expected_state' in ${timeout_seconds}s."
    return 1
}

if [ "$ALLOW_DIRTY" != "1" ] && [ -n "$(git status --short)" ]; then
    echo "Refusing to deploy from a dirty working tree."
    echo "Commit or stash local changes first, or rerun with ALLOW_DIRTY=1 if intentional."
    exit 1
fi

git fetch --all --prune

if [ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]; then
    git checkout "$TARGET_BRANCH"
fi

git pull --ff-only

UPDATED_COMMIT="$(git rev-parse HEAD)"
SHORT_COMMIT="$(git rev-parse --short=12 HEAD)"
export NETDOC_IMAGE_TAG="netdoc-${SHORT_COMMIT}"
echo "Deploying commit: $UPDATED_COMMIT"
echo "Docker image tag: netbox:${NETDOC_IMAGE_TAG}"

compose up -d postgres redis redis-cache
wait_for_container_state netbox-docker-postgres-1 healthy 120
wait_for_container_state netbox-docker-redis-1 healthy 60
wait_for_container_state netbox-docker-redis-cache-1 healthy 60
docker image rm -f "netbox:${NETDOC_IMAGE_TAG}" || true
compose build --pull --no-cache netbox netbox-worker
compose run --rm --no-deps netbox /opt/netbox/venv/bin/python -c "import pathlib, netdoc; print('Imported:', netdoc.__file__); source = pathlib.Path(netdoc.__file__).read_text(); assert 'getattr(extras_models, \"ReportModule\", None)' in source; print('NetDoc image verification passed')"
compose up -d --remove-orphans --force-recreate netbox
if ! wait_for_container_state netbox-docker-netbox-1 healthy "$NETBOX_STARTUP_TIMEOUT"; then
    echo "NetBox container did not become healthy in time."
    compose logs --tail=100 netbox
    exit 1
fi
compose up -d --remove-orphans --force-recreate netbox-worker
wait_for_container_state netbox-docker-netbox-worker-1 healthy "$NETBOX_WORKER_STARTUP_TIMEOUT"
compose exec -T netbox /opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py shell -c "from netdoc import sync_plugin_assets; sync_plugin_assets(); print('NetDoc asset sync passed')"
compose logs --tail=100 netbox
