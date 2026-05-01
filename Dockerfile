# ─────────────────────────────────────────────────────────────
#  Stage 1 – Dependency installer
#  Uses full Node image to install packages, then copies only
#  the production node_modules into the final slim image.
# ─────────────────────────────────────────────────────────────
FROM node:20-alpine AS deps

# Install dumb-init for proper signal handling (PID 1)
RUN apk add --no-cache dumb-init

WORKDIR /build

# Copy only manifests first – maximises Docker layer cache
COPY package.json package-lock.json* ./

# Install production dependencies only
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

# ─────────────────────────────────────────────────────────────
#  Stage 2 – Runtime image
# ─────────────────────────────────────────────────────────────
FROM node:20-alpine AS runtime

# Security: run as non-root user
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copy dumb-init from deps stage
COPY --from=deps /usr/bin/dumb-init /usr/bin/dumb-init

# Copy node_modules from deps stage
COPY --from=deps /build/node_modules ./node_modules

# Copy application source
COPY --chown=appuser:appgroup app/src    ./src
COPY --chown=appuser:appgroup app/public ./public
COPY --chown=appuser:appgroup app/package.json ./

USER appuser

# Port the app listens on
EXPOSE 3000

# Health check – Docker will mark container unhealthy if /health fails
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

# Entrypoint: dumb-init ensures SIGTERM is forwarded correctly
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/index.js"]
