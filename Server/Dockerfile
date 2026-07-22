# Budget API server. One image, two roles:
#   - `serve` (default CMD): the Vapor API
#   - one-off commands (compose `run --rm server <cmd>`): sync-all,
#     networth-snapshot, bill-reminder
#
# Build from the REPO ROOT so the ../Packages/BudgetCore path dependency
# resolves:  docker build -f Server/Dockerfile .
# (docker-compose.yml sets this context for you.)

# ================================ Build stage ================================
FROM swift:6.1-noble AS build

# GRDB links the system SQLite on Linux.
RUN export DEBIAN_FRONTEND=noninteractive \
 && apt-get -q update \
 && apt-get -q install -y libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Manifests first, so dependency resolution caches across source edits.
COPY Server/Package.swift Server/Package.resolved ./Server/
COPY Packages ./Packages
WORKDIR /build/Server
RUN swift package resolve

# Tests must be present for SPM to accept the manifest's testTarget.
COPY Server/Sources ./Sources
COPY Server/Tests ./Tests
RUN swift build -c release --product App --static-swift-stdlib

# Stage the runtime payload.
WORKDIR /staging
RUN cp "$(swift build -c release --show-bin-path --package-path /build/Server)/App" ./ \
 && if [ -f /usr/libexec/swift/linux/swift-backtrace-static ]; then \
      cp /usr/libexec/swift/linux/swift-backtrace-static ./; \
    fi

# =============================== Runtime stage ===============================
FROM ubuntu:24.04

# sqlite3 CLI: scripts/backup-db.sh runs `.backup` inside the container for
# online, WAL-safe backups of the mounted database.
RUN export DEBIAN_FRONTEND=noninteractive \
 && apt-get -q update \
 && apt-get -q install -y --no-install-recommends \
      libsqlite3-0 sqlite3 ca-certificates tzdata curl \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor

WORKDIR /app
COPY --from=build --chown=vapor:vapor /staging /app
# The SQLite file (and backups) live on this mounted volume.
RUN mkdir -p /data && chown -R vapor:vapor /data
VOLUME /data

ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static
ENV BUDGET_DB_PATH=/data/budget.sqlite

USER vapor:vapor
EXPOSE 8080
ENTRYPOINT ["./App"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
