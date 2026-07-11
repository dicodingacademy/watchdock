# ghcr-compose-updater
# Base: official docker:27-cli (alpine) — already ships with the
# `docker compose` plugin, so we only add curl + jq on top.
FROM docker:27-cli

RUN apk add --no-cache curl jq

COPY updater.sh /usr/local/bin/updater.sh

ENTRYPOINT ["sh", "/usr/local/bin/updater.sh"]