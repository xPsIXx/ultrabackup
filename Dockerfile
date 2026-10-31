# Ultra Explorer — subscription-ungated build
#
# Builds from the official upstream image and patches the bundled ultra-server
# binary to render every product-access capability as "allowed".
# See SUBSCRIPTION_REMOVALS.md for what/why and how to re-apply on updates.
#
# Build:  docker build -t ultra-explorer:ungated --build-arg UPSTREAM=ghcr.io/sudo-rahman/ultra-explorer:latest .
# Run:    docker run -d --name ultra -p 7373:7373 -v ultra-data:/data \
#              --add-host ultra-explorer.app:127.0.0.1 \
#              -e ULTRA_ADMIN_PASSWORD='...' -e ULTRA_LOCAL_ROOTS=/mnt/local \
#              -v /path/to/local/files:/mnt/local ultra-explorer:ungated
#
# The --add-host flag is the telemetry removal: the backend's only external
# call is license verification to ultra-explorer.app (sends installationId).
# Pointing it at 127.0.0.1 stops all phone-home; patches A+B+C make the
# entitlement gate independent of that call, so nothing breaks.

ARG UPSTREAM=ghcr.io/sudo-rahman/ultra-explorer:1.3.0
FROM ${UPSTREAM}

# base image runs as unprivileged user 'ultra' — patching needs root
USER root
COPY ungate.sh /tmp/ungate.sh
RUN sh /tmp/ungate.sh /usr/local/bin/ultra-server \
    && rm -f /tmp/ungate.sh
USER ultra:ultra
