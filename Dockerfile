# AccOps - container image for Coolify deployment
# Backend: FastAPI (uvicorn on 127.0.0.1:17893)
# Frontend: Vite dev server (0.0.0.0:17894, proxies /api + ws to backend)
# Headed Chrome via Xvfb (Google login blocks headless mode)
FROM python:3.12-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates gnupg procps \
      xvfb chromium fonts-noto-cjk \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && corepack enable \
    && corepack prepare pnpm@9 --activate \
    && pip install --no-cache-dir uv \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 accops

WORKDIR /app
COPY backend ./backend
COPY frontend ./frontend

RUN cd /app/backend && uv sync --frozen
RUN cd /app/frontend && pnpm install --frozen-lockfile

# Browser profiles persist via a volume mounted here (Coolify storage)
RUN mkdir -p /app/backend/.browser_profiles \
    && chown -R accops:accops /app

COPY docker-entrypoint.sh /entrypoint.sh
# 755, not just +x: the container runs as non-root and the script
# interpreter must be able to READ the file (a 771 copy fails).
RUN chmod 755 /entrypoint.sh

# Run as non-root: Chrome refuses --no-sandbox-less launch as root,
# and DrissionPage does not pass --no-sandbox itself.
USER accops
EXPOSE 17894
ENTRYPOINT ["/entrypoint.sh"]
