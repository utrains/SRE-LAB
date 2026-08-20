const express = require("express");
const tracer = require("./tracer");

// In-memory chaos state. Toggled via HTTP so scripts/chaos/*.sh can trigger
// failure modes with a curl call against a running pod -- no redeploy needed.
const state = {
  latencyMs: Number(process.env.CHAOS_LATENCY_MS || 0),
  errorRate: Number(process.env.CHAOS_ERROR_RATE || 0),
  dbDrop: process.env.CHAOS_DB_DROP === "true",
  memoryHogs: [],
};

function isDbDropActive() {
  return state.dbDrop;
}

// Applied globally: injects latency and random 500s ahead of real handlers.
function chaosMiddleware(req, res, next) {
  // /healthz and /readyz are the actual liveness/readiness probes (see
  // apps/<app>/k8s/deployment-backend.yaml) -- latency/error injection must
  // not touch them, or kubelet restarts the pod as an unintended side
  // effect. isDbDropActive() in index.js's /readyz handler is a separate,
  // intentional mechanism and is unaffected by this exemption.
  if (
    req.path.startsWith("/api/chaos") ||
    req.path === "/healthz" ||
    req.path === "/readyz"
  ) {
    return next();
  }

  const finish = () => {
    if (state.errorRate > 0 && Math.random() < state.errorRate) {
      const err = new Error(`chaos: injected failure on ${req.method} ${req.path}`);
      console.error("chaos error injection fired:", err.stack);
      const span = tracer.scope().active();
      if (span) span.setTag("error", err);
      return res.status(500).json({ error: "chaos: injected failure" });
    }
    next();
  };

  if (state.latencyMs > 0) {
    setTimeout(finish, state.latencyMs);
  } else {
    finish();
  }
}

const router = express.Router();

router.get("/", (req, res) => {
  res.json({
    latencyMs: state.latencyMs,
    errorRate: state.errorRate,
    dbDrop: state.dbDrop,
    memoryHogMb: state.memoryHogs.length * 10,
  });
});

router.post("/latency", (req, res) => {
  state.latencyMs = Number(req.body?.ms ?? 0);
  res.json({ ok: true, latencyMs: state.latencyMs });
});

router.post("/errors", (req, res) => {
  state.errorRate = Math.max(0, Math.min(1, Number(req.body?.rate ?? 0)));
  res.json({ ok: true, errorRate: state.errorRate });
});

router.post("/db-drop", (req, res) => {
  state.dbDrop = Boolean(req.body?.enabled);
  res.json({ ok: true, dbDrop: state.dbDrop });
});

// Blocks the event loop on purpose -- demonstrates high latency / saturation
// across every request this pod serves, not just the caller's.
router.post("/cpu-spike", (req, res) => {
  const seconds = Number(req.body?.seconds ?? 10);
  const end = Date.now() + seconds * 1000;
  res.json({ ok: true, seconds });
  while (Date.now() < end) {
    Math.sqrt(Math.random());
  }
});

// Retains memory until /reset is called -- pairs with a low memory limit on
// the Deployment to demonstrate OOMKilled.
router.post("/memory-spike", (req, res) => {
  const mb = Number(req.body?.mb ?? 50);
  const chunks = Math.ceil(mb / 10);
  for (let i = 0; i < chunks; i++) {
    state.memoryHogs.push(Buffer.alloc(10 * 1024 * 1024, 1));
  }
  res.json({ ok: true, retainedMb: state.memoryHogs.length * 10 });
});

router.post("/reset", (req, res) => {
  state.latencyMs = 0;
  state.errorRate = 0;
  state.dbDrop = false;
  state.memoryHogs = [];
  res.json({ ok: true });
});

module.exports = { router, chaosMiddleware, isDbDropActive };
