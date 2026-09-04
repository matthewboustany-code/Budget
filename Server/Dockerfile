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

# GRDB links the system SQLite on Linux, so we give it SQLCipher instead of
# stock SQLite. SQLCipher is a fork of SQLite with the same API and ABI plus
# the `PRAGMA key` family, so aliasing it into libsqlite3's place transparently
# gets us an encrypted database with an unmodified, unforked GRDB. (GRDB's own
# SQLCipher instructions require editing ITS Package.swift, i.e. vendoring a
# fork of it — much worse to live with than two symlinks.)
#
# AppDatabase verifies at runtime that `PRAGMA cipher_version` actually answers,
# so if this aliasing ever silently stops working the server refuses to boot
# rather than writing financial data in the clear.
RUN export DEBIAN_FRONTEND=noninteractive \
 && apt-get -q update \
 && apt-get -q install -y --no-install-recommends libsqlcipher-dev \
 && ln -sf /usr/lib/x86_64-linux-gnu/libsqlcipher.so /usr/lib/x86_64-linux-gnu/libsqlite3.so \
 && ln -sf /usr/include/sqlcipher/sqlite3.h /usr/include/sqlite3.h \
 && ln -sf /usr/include/sqlcipher/sqlite3ext.h /usr/include/sqlite3ext.h \
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
FROM ubuntu:26.04

# libsqlcipher1 is what the binary is linked against (see the build stage), and
# must be aliased the same way so the dynamic loader finds it as libsqlite3.
#
# The `sqlcipher` CLI replaces the `sqlite3` one: scripts/backup-db.sh runs
# `.backup` inside the container for online, WAL-safe backups, and an encrypted
# database can only be opened by a client that understands PRAGMA key. It is
# symlinked as `sqlite3` too so existing scripts and muscle memory keep working.
RUN export DEBIAN_FRONTEND=noninteractive \
 && apt-get -q update \
 && apt-get -q install -y --no-install-recommends \
      libsqlcipher1 sqlcipher ca-certificates tzdata curl \
 && ln -sf /usr/lib/x86_64-linux-gnu/libsqlcipher.so.1 /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 \
 && ln -sf /usr/bin/sqlcipher /usr/bin/sqlite3 \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor

WORKDIR /app
COPY --from=build --chown=vapor:vapor /staging /app
# The SQLite file (and backups) live on this mounted volume.
RUN mkdir -p /data && chown -R vapor:vapor /data
VOLUME /data

ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static
ENV BUDGET_DB_PATH=/data/budget.sqlite
# Applies to EVERY invocation, not just `serve` — the one-off commands
# (sync-all, bill-reminder, …) would otherwise default to development, which
# turns dev auth on and skips the production config validation. Vapor takes
# VAPOR_ENV as the fallback for `--env`, so `--env` still overrides it.
ENV VAPOR_ENV=production

USER vapor:vapor
EXPOSE 8080
ENTRYPOINT ["./App"]
CMD ["serve", "--hostname", "0.0.0.0", "--port", "8080"]
