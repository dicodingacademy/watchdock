#!/bin/sh
# ghcr-compose-updater
#
# Generic auto-updater for docker compose stacks using GHCR images with
# immutable tags (e.g. sha-<commit>). Watchtower-style, but label-driven
# and pin-based: deployed tags live in the compose .env file, so state is
# explicit, auditable, and trivially rollback-able.
#
# HOW IT WORKS
#   Each cycle, services are discovered from the compose file itself via
#   labels — no per-project script changes needed:
#
#     services:
#       myapp:
#         image: ghcr.io/myorg/myapp:${MYAPP_TAG:?}
#         labels:
#           auto-update.tag-var: MYAPP_TAG    # required: pin var in .env
#           auto-update.priority: "10"        # optional: lower runs first
#                                             #   (default 100)
#
#   For each labeled service: query the GitHub Packages API for the newest
#   tag matching TAG_PATTERN -> if it differs from the pin in .env:
#   pull -> update pin -> `compose up -d <service>`. On restart failure
#   the pin is reverted so the next cycle retries cleanly.
#
# CONFIGURATION (env vars)
#   GITHUB_TOKEN   required. PAT with read:packages (also used for GHCR pull)
#   GHCR_USER      username for `docker login ghcr.io` (default: token)
#   COMPOSE_FILE   default /compose/docker-compose.yml
#   ENV_FILE       default /compose/.env
#   POLL_INTERVAL  seconds between cycles (default 300)
#   TAG_PATTERN    regex for deployable tags (default ^sha-[0-9a-f]{7,40}$)
#   VERBOSE        1 = log every check even when up-to-date (default 0)
#
# REQUIREMENTS
#   docker CLI + compose plugin, curl, jq. The compose file should set a
#   top-level `name:` so the project resolves identically from inside the
#   updater container and from the host.

COMPOSE_FILE=${COMPOSE_FILE:-/compose/docker-compose.yml}
ENV_FILE=${ENV_FILE:-/compose/.env}
POLL_INTERVAL=${POLL_INTERVAL:-300}
TAG_PATTERN=${TAG_PATTERN:-^sha-[0-9a-f]{7,40}$}
GHCR_USER=${GHCR_USER:-token}
VERBOSE=${VERBOSE:-0}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

compose() {
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

# Emits one line per labeled service, priority-sorted:
#   <priority> <service> <image_repo> <tag_var>
discover_services() {
  compose config --format json 2>/dev/null \
  | jq -r '
      .services | to_entries[]
      | select(.value.labels != null and .value.labels["auto-update.tag-var"] != null)
      | select(.value.image | startswith("ghcr.io/"))
      | [ (.value.labels["auto-update.priority"] // "100"),
          .key,
          (.value.image | split(":")[0]),
          .value.labels["auto-update.tag-var"] ]
      | @tsv' \
  | sort -n
}

# Newest tag matching TAG_PATTERN from the GitHub Packages API.
# Org and package are derived from the image repo (ghcr.io/<org>/<package>).
# Versions come back newest-first; untagged versions and non-matching tags
# (e.g. "latest") are skipped.
get_latest_tag() {
  repo=$1
  org=$(echo "$repo" | cut -d/ -f2)
  package=$(echo "$repo" | cut -d/ -f3)
  curl -sf --max-time 30 \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${org}/packages/container/${package}/versions?per_page=10" \
  | jq -r --arg pat "$TAG_PATTERN" \
      '[.[] | .metadata.container.tags[]? | select(test($pat))] | first // empty'
}

get_current_tag() {
  grep "^${1}=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2
}

# Rewrites the pin by truncating in place (cat >) instead of sed -i, which
# replaces the file and would break the inode, owner and mode of ENV_FILE.
set_env_tag() {
  var=$1
  tag=$2
  if grep -q "^${var}=" "$ENV_FILE" 2>/dev/null; then
    tmp="${ENV_FILE}.tmp.$$"
    sed "s|^${var}=.*|${var}=${tag}|" "$ENV_FILE" > "$tmp" \
      && cat "$tmp" > "$ENV_FILE"
    rm -f "$tmp"
  else
    echo "${var}=${tag}" >> "$ENV_FILE"
  fi
}

check_and_update() {
  service=$1
  repo=$2
  var=$3

  # tag-var must be a valid env var name: it is interpolated into grep/sed
  # patterns and written to ENV_FILE
  case $var in
    ""|[0-9]*|*[!A-Za-z0-9_]*)
      log "WARN: skipping $service: invalid tag-var name '$var'"
      return 0
      ;;
  esac

  latest_tag=$(get_latest_tag "$repo")
  if [ -z "$latest_tag" ]; then
    log "WARN: could not resolve latest tag for $repo (API error or no matching tags)"
    return 0
  fi

  # defense in depth: even with a loosened TAG_PATTERN, never let characters
  # outside the docker tag charset reach the sed replacement / ENV_FILE
  case $latest_tag in
    *[!A-Za-z0-9._-]*)
      log "WARN: ignoring tag with unsafe characters for $repo: $latest_tag"
      return 0
      ;;
  esac

  current_tag=$(get_current_tag "$var")
  if [ "$latest_tag" = "$current_tag" ]; then
    [ "$VERBOSE" = "1" ] && log "$service up-to-date ($current_tag)"
    return 0
  fi

  log "New version for $service: ${current_tag:-<none>} -> $latest_tag, pulling..."

  if ! pull_output=$(docker pull -q "${repo}:${latest_tag}" 2>&1); then
    log "WARN: pull failed for ${repo}:${latest_tag}: $pull_output"
    return 0
  fi

  set_env_tag "$var" "$latest_tag"

  if compose up -d "$service"; then
    log "$service now running $latest_tag"
  else
    log "ERROR: failed to restart $service on $latest_tag"
    # revert pin so the next cycle retries cleanly
    [ -n "$current_tag" ] && set_env_tag "$var" "$current_tag"
  fi
}

# ---- startup checks ---------------------------------------------------

if [ -z "$GITHUB_TOKEN" ]; then
  log "FATAL: GITHUB_TOKEN is not set (needs read:packages scope)"
  exit 1
fi

# GHCR pulls authenticate CLI-side from this container's docker config,
# so login here even if the host daemon is already logged in.
if ! echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null 2>&1; then
  log "FATAL: docker login ghcr.io failed — check token validity/scope"
  exit 1
fi
log "Logged in to ghcr.io."

services=$(discover_services)
if [ -z "$services" ]; then
  log "WARN: no services with 'auto-update.tag-var' labels found in $COMPOSE_FILE"
else
  count=$(echo "$services" | wc -l)
  log "Discovered $count service(s):"
  echo "$services" | while read -r prio service repo var; do
    log "  - $service ($repo, var=$var, priority=$prio)"
  done
fi

log "Updater started. Polling every ${POLL_INTERVAL}s. Tag pattern: $TAG_PATTERN"

# ---- main loop ---------------------------------------------------------

last_heartbeat=$(date +%s)

while true; do
  # rediscover each cycle so compose file edits are picked up live
  discover_services | while read -r prio service repo var; do
    check_and_update "$service" "$repo" "$var"
  done

  docker image prune -f >/dev/null 2>&1 || true

  # hourly heartbeat so "no output" never means "maybe dead"
  now=$(date +%s)
  if [ $((now - last_heartbeat)) -ge 3600 ]; then
    log "heartbeat: alive, no updates in the last hour"
    last_heartbeat=$now
  fi

  sleep "$POLL_INTERVAL"
done