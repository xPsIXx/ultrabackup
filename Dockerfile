# Ultra Explorer — subscription-ungated build
#
# Builds from the official upstream image and patches the bundled ultra-server
# binary to render every product-access capability as "allowed".
# See SUBSCRIPTION_REMOVALS.md for what/why and how to re-apply on updates.
#
# Build:  docker build -t ultra-explorer:ungated --build-arg UPSTREAM=ghcr.io/sudo-rahman/ultra-explorer:latest .
# Run:    docker run -d --name ultra -p 7373:7373 -v ultra-data:/data \
#              -e ULTRA_ADMIN_PASSWORD='...' -e ULTRA_LOCAL_ROOTS=/mnt/local \
#              -v /path/to/local/files:/mnt/local ultra-explorer:ungated

ARG UPSTREAM=ghcr.io/sudo-rahman/ultra-explorer:latest
FROM ${UPSTREAM}

# base image runs as unprivileged user 'ultra' — patching needs root
USER root
COPY ungate.sh /tmp/ungate.sh
RUN sh /tmp/ungate.sh /usr/local/bin/ultra-server \
    && rm -f /tmp/ungate.sh
USER ultra:ultra
