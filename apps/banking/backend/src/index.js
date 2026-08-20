require("./tracer");

const express = require("express");
const cors = require("cors");
const { checkConnection } = require("./db");
const { router: chaosRouter, chaosMiddleware, isDbDropActive } = require("./chaos");
const apiRoutes = require("./routes");

const app = express();
const PORT = process.env.PORT || 4000;

app.use(cors());
app.use(express.json());
app.use(chaosMiddleware);

app.get("/healthz", (req, res) => {
  res.json({ status: "ok" });
});

app.get("/readyz", async (req, res) => {
  // Both failure paths log the reason, not just the status code. A pod that
  // fails readiness is pulled out of the Service and stops receiving API
  // traffic, so nothing else it does will ever reach the logs -- this line
  // is the only thing that explains itself in Datadog (search
  // `service:<app>-backend status:error`). It repeats once per failed probe,
  // every 10s, per the readinessProbe in k8s/deployment-backend.yaml.
  if (isDbDropActive()) {
    console.error("readiness check failed: db connection dropped (chaos)");
    return res.status(503).json({ status: "not ready", reason: "db connection dropped (chaos)" });
  }
  try {
    await checkConnection();
    res.json({ status: "ready" });
  } catch (err) {
    console.error("readiness check failed:", err.message);
    res.status(503).json({ status: "not ready", reason: err.message });
  }
});

app.use("/api/chaos", chaosRouter);
app.use("/api", apiRoutes);

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: "internal server error" });
});

app.listen(PORT, () => {
  console.log(`banking-backend listening on ${PORT}`);
});
