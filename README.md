# ghcr-compose-updater

Generic auto-updater for docker compose stacks that deploy GHCR images with
immutable tags (e.g. `sha-<commit>` from docker/metadata-action). Watchtower-style
polling, but label-driven and **pin-based**: deployed tags live in the compose
`.env` file, so deployment state is explicit, auditable, and rollback is a
one-line edit.

## How it works

Every `POLL_INTERVAL` seconds, for each labeled service:

1. Query the GitHub Packages API for the newest tag matching `TAG_PATTERN`
2. If it differs from the pin in `.env`: pull → update pin → `compose up -d <service>`
3. If the restart fails, the pin is reverted and the next cycle retries

Services are discovered from the compose file itself — adding a service to the
update rotation is just adding labels. No updater config changes.

## Dropping into a project

**1.** Use the prebuilt image `ghcr.io/<owner>/watchdock:latest` (published by
this repo's CI), or copy `Dockerfile` + `updater.sh` from the repo root into a
directory next to your compose file if you prefer building it yourself.

**2.** Pin a project name at the top of your compose file (required — without
it, compose inside the container resolves a different project and will spawn a
duplicate stack):

```yaml
name: myproject
```

**3.** Use variable tags + labels on each service you want auto-updated:

```yaml
services:
  myapp:
    image: ghcr.io/myorg/myapp:${MYAPP_TAG:?set in .env}
    labels:
      auto-update.tag-var: MYAPP_TAG    # required: name of the pin var in .env
      auto-update.priority: "10"        # optional: lower runs first (default 100)
```

Services **without** the label are never touched. Dependency services that share
a tag var (e.g. a migration job using the same image) should NOT be labeled —
they get recreated automatically via `depends_on` when the labeled service updates.

**4.** Add the updater service:

```yaml
  updater:
    image: ghcr.io/<owner>/watchdock:latest
    # or, if you copied the files instead:
    # build: ./updater
    environment:
      GITHUB_TOKEN: ${GHCR_READ_TOKEN:?PAT with read:packages}
      POLL_INTERVAL: "300"
      # VERBOSE: "1"                      # log every check
      # TAG_PATTERN: "^sha-[0-9a-f]+$"    # override tag regex
      # GHCR_USER: your-github-username
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./:/compose
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

**5.** Seed `.env` with current tags + the token:

```
MYAPP_TAG=sha-abc1234
GHCR_READ_TOKEN=ghp_xxxx
```

**6.** `docker compose up -d updater` (add `--build` if you build it locally)

## Configuration reference

| Env var         | Default                       | Purpose                                    |
|-----------------|-------------------------------|--------------------------------------------|
| `GITHUB_TOKEN`  | (required)                    | PAT with `read:packages`; also used for GHCR pull |
| `GHCR_USER`     | `token`                       | Username for `docker login ghcr.io`        |
| `COMPOSE_FILE`  | `/compose/docker-compose.yml` | Compose file path inside the container     |
| `ENV_FILE`      | `/compose/.env`               | Env file holding the tag pins              |
| `POLL_INTERVAL` | `300`                         | Seconds between cycles                     |
| `TAG_PATTERN`   | `^sha-[0-9a-f]{7,40}$`        | Regex for deployable tags                  |
| `VERBOSE`       | `0`                           | `1` = log every check, even when up-to-date |

## Operations

**Rollback:** edit the tag var in `.env` to an older SHA, then
`docker compose up -d <service>`. The updater won't fight you unless a *newer*
version is published to GHCR.

**Logs:** `docker compose logs -f updater`. An hourly heartbeat is logged, so
silence longer than an hour means something is wrong.

**Security note:** mounting `docker.sock` grants this container effective root
on the host (standard for this pattern — Watchtower does the same). Keep the
PAT minimal-scope (`read:packages` only).

## Requirements

- GHCR images in an **org** (API path uses `/orgs/`), private or public
- Immutable tags matching `TAG_PATTERN` pushed by CI
- PAT with `read:packages` (SSO-authorized if the org enforces SAML)