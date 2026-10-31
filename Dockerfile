# Multi-stage build for the treg (tools-registry) server.
#
# Stage 1 builds the Vue/Vite dashboard, which is compiled into the Python package
# (src/treg/web/dashboard/) and is NOT committed, so Node is required at build time only.
# Stage 2 is the runtime: Python 3.13 + the locked [server] extra, no Node.

# ---------------------------------------------------------------------------
# Stage 1 - dashboard build
# ---------------------------------------------------------------------------
FROM node:22-bookworm-slim AS dashboard

WORKDIR /repo
COPY . .

# The build writes to ../src/treg/web/dashboard and reads ../src/treg/web/*.html, so frontend/
# and src/ must stay siblings exactly as in the checkout. `--include=dev` keeps vue-tsc/vite.
RUN npm --prefix frontend ci --include=dev --no-audit --no-fund \
    && npm --prefix frontend run build

# ---------------------------------------------------------------------------
# Stage 2 - runtime
# ---------------------------------------------------------------------------
FROM python:3.13-slim-bookworm AS runtime

# uv follows uv.lock exactly; the tag must satisfy `required-version` in pyproject.toml.
COPY --from=ghcr.io/astral-sh/uv:0.12.3 /uv /usr/local/bin/uv

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/usr/local \
    PATH="/usr/local/bin:$PATH"

WORKDIR /app

# `quickjs` (the hub's script sandbox engine) ships no manylinux wheel, so a C toolchain is needed
# to compile it. It is kept out of the final image below.
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

# Dependency layer: resolve from the lockfile alone. --no-install-project keeps this layer from
# building the project's metadata (which needs src/, README.md and LICENSE) before they are copied.
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --extra server --no-install-project

# Application source, then the dashboard built in stage 1.
COPY . .
COPY --from=dashboard /repo/src/treg/web/dashboard ./src/treg/web/dashboard

# Install the project itself (editable, so the dashboard copied above is picked up at runtime),
# then drop the compiler toolchain now that quickjs has been built.
RUN uv sync --locked --no-dev --extra server \
    && apt-get purge -y --auto-remove build-essential \
    && rm -rf /var/lib/apt/lists/*

# Run unprivileged. /data is the optional sqlite fallback when no Postgres is configured.
RUN useradd --create-home --uid 10001 treg \
    && mkdir -p /data \
    && chown -R treg:treg /app /data
USER treg

# Railway injects PORT and routes/health-checks that port. `python -m treg` honors $PORT and runs
# the release phase (alembic upgrade head + idempotent tasks) before serving.
ENV PORT=8080
EXPOSE 8080

CMD ["python", "-m", "treg"]