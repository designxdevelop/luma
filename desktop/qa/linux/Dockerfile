FROM node:24-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libasound2 \
    libgtk-3-0 libx11-xcb1 libxshmfence1 libsecret-1-0 xvfb xauth \
    && rm -rf /var/lib/apt/lists/*
USER node
WORKDIR /workspace
