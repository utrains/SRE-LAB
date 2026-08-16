import { datadogRum } from "@datadog/browser-rum";

// Must be imported before App.jsx (see main.jsx) so RUM captures the
// initial page load. applicationId/clientToken/service/env/version come
// from build-time VITE_ env vars (baked in via Dockerfile ARG/ENV, set by
// scripts/setup.sh's RUM provisioning step) rather than being hardcoded,
// so this file is identical across every app in the lab -- same pattern as
// the backend's src/tracer.js. No-ops if setup.sh ran without Datadog
// credentials, since there's then no applicationId/clientToken to init with.
const applicationId = import.meta.env.VITE_DD_APPLICATION_ID;
const clientToken = import.meta.env.VITE_DD_CLIENT_TOKEN;

if (applicationId && clientToken) {
  datadogRum.init({
    applicationId,
    clientToken,
    site: import.meta.env.VITE_DD_SITE || "datadoghq.com",
    service: import.meta.env.VITE_DD_SERVICE,
    env: import.meta.env.VITE_DD_ENV,
    version: import.meta.env.VITE_DD_VERSION,
    sessionSampleRate: 100,
    // Session Replay is a separate feature from tracing/RUM metrics -- left
    // off by default to keep this focused on APM correlation, not because
    // of any technical requirement. Bump this if you want it too.
    sessionReplaySampleRate: 0,
    // The frontend's own origin: nginx proxies /api/* to the backend
    // Service internally (see nginx.conf), so from the browser every API
    // call is same-origin -- this is what makes a RUM session's spans
    // stitch to the matching backend APM trace (see
    // https://docs.datadoghq.com/real_user_monitoring/platform/connect_rum_and_traces/).
    allowedTracingUrls: [window.location.origin],
  });
}
