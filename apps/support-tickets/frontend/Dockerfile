FROM --platform=$BUILDPLATFORM node:22-alpine AS build
WORKDIR /app
# Datadog RUM config (see src/rum.js) is baked into the static bundle at
# build time -- Vite only exposes VITE_-prefixed vars present in the build
# environment, there's no runtime env injection for a static SPA served by
# nginx. Left unset (default), the frontend just runs without RUM -- see
# scripts/setup.sh's RUM provisioning step, which only sets these when
# DATADOG_API_KEY and DATADOG_APP_KEY are both provided.
ARG VITE_DD_APPLICATION_ID
ARG VITE_DD_CLIENT_TOKEN
ARG VITE_DD_SITE
ARG VITE_DD_SERVICE
ARG VITE_DD_ENV
ARG VITE_DD_VERSION
ENV VITE_DD_APPLICATION_ID=$VITE_DD_APPLICATION_ID \
    VITE_DD_CLIENT_TOKEN=$VITE_DD_CLIENT_TOKEN \
    VITE_DD_SITE=$VITE_DD_SITE \
    VITE_DD_SERVICE=$VITE_DD_SERVICE \
    VITE_DD_ENV=$VITE_DD_ENV \
    VITE_DD_VERSION=$VITE_DD_VERSION
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:1.27-alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
