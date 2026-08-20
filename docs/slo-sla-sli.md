# SLIs, SLOs, and SLAs

These three terms get used interchangeably in casual conversation, but they
mean different things and sit at different layers:

- **SLI (Service Level Indicator)** -- a *measurement*. A number you can
  actually query in Datadog right now, e.g. "the p95 latency of
  `POST /api/checkout` over the last 5 minutes."
- **SLO (Service Level Objective)** -- a *target* for that measurement that
  your team commits to internally, e.g. "99.5% of checkout requests
  complete in under 500ms, measured over a rolling 30 days." SLOs are how
  you decide whether you're doing okay, before a customer tells you
  otherwise.
- **SLA (Service Level Agreement)** -- a *promise* to someone external
  (a customer, a paying tier), usually with a financial or contractual
  consequence if you miss it. SLAs are almost always looser than the
  internal SLO backing them, so you have room to notice and fix a problem
  before you're in breach of an actual contract.

A useful mental model: **SLI is what you measure, SLO is the bar you hold
yourself to, SLA is the bar someone else holds you to.**

## Per-app examples

Each row below is a concrete, queryable example -- not a placeholder --
using the actual endpoints and metrics this lab's apps emit via `dd-trace`.

### ecommerce

| | |
|---|---|
| SLI | p95 latency of `POST /api/checkout`, measured via `p95:trace.express.request{service:ecommerce-backend,resource:POST /api/checkout}` |
| SLO | 99.5% of checkout requests complete in under 500ms, over a rolling 30 days |
| SLA | If checkout latency exceeds 500ms on average for more than 1 hour in a billing period, affected merchants receive a 5% credit for that month |

### banking

| | |
|---|---|
| SLI | Success rate of `POST /api/transfer` (non-5xx responses / total requests) |
| SLO | 99.9% of transfer requests succeed without a 5xx error, over a rolling 30 days |
| SLA | 99.5% monthly availability of funds transfers, per the customer terms of service |

### food-delivery

| | |
|---|---|
| SLI | Cache hit ratio on `GET /api/orders/:id/status`, and p95 latency of that endpoint |
| SLO | 95% of order-status polls are served in under 200ms, over a rolling 7 days |
| SLA | None external -- this is an internal-only SLO backing the "live tracking" feature, not a contractual promise to diners |

### student-portal

| | |
|---|---|
| SLI | Error rate of `GET /api/grades` and `GET /api/courses` |
| SLO | 99.5% of grade/course lookups succeed, over a rolling 30 days, measured only during the academic term |
| SLA | 99% uptime during posted business hours, per the institution's IT services agreement |

### support-tickets

| | |
|---|---|
| SLI | p95 latency and error rate of `POST /api/tickets` (ticket creation) |
| SLO | 99.9% of ticket submissions succeed in under 300ms, over a rolling 30 days |
| SLA | None -- internal tool, no external SLA, but the SLO still matters because a slow/broken intake form directly delays every downstream support response |

## Where to find these in Datadog

Each app's dashboard (`datadog/dashboards/<app>.json`) plots the request
throughput, error rate, and p95 latency that back these SLIs. The
`[SRE Lab] High error rate` and `[SRE Lab] High p95 latency` monitors
(`datadog/monitors/`) are set to warn/alert at thresholds tighter than the
SLOs above, so you get paged before you've actually burned through the
error budget -- see `docs/error-budget.md`.
