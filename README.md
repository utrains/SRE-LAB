# SRE Lab

A hands-on DevOps and SRE troubleshooting lab with five full-stack applications on Amazon EKS. The applications use Amazon RDS for PostgreSQL, public traffic enters through Route 53 and a shared Application Load Balancer, images live in ECR, and Datadog provides metrics, events, logs, traces, dashboards, and monitors.

The training loop is:

```text
Datadog symptom -> scope -> Kubernetes or AWS evidence -> root cause -> fix -> Datadog recovery
```

## Architecture

```text
User -> Route 53 -> ALB -> Kubernetes Ingress -> Service -> Pod
                                                        |
                                                        v
                                               RDS PostgreSQL

ECR -> Kubernetes Deployment -> Pod
Datadog Agent + Cluster Agent -> metrics, events, logs, and APM
```

Five applications share the EKS cluster: `ecommerce`, `banking`, `food-delivery`, `student-portal`, and `support-tickets`. Each has a React/nginx frontend and Node.js/Express backend. See [Architecture](docs/architecture.md) for the full design and training tradeoffs.

## Repository layout

```text
apps/                  Application source and Kubernetes manifests
datadog/               Helm values, dashboards, and monitors
docs/                  Student, instructor, scenario, runbook, and PDF material
ingress/               One hostname-based Ingress per application
namespaces/            Namespaces, quotas, and limit ranges
scripts/               Setup, teardown, PDF generation, and chaos triggers
terraform/             VPC, EKS, ECR, RDS, Route 53, IAM, and ALB controller
```

## Prerequisites

- Bash 4.4 or newer
- Terraform, AWS CLI, kubectl, Docker, Helm, jq, `envsubst`, `curl`, and `nslookup`
- An AWS account with credentials configured
- An existing Route 53 public hosted zone with registrar delegation already configured
- A Datadog account and API key; an application key is needed to import dashboards/monitors and provision RUM
- Budget for real EKS, EC2, NAT Gateway, ALB, Route 53, and RDS resources

The fixed resource names support one lab deployment per AWS account. macOS users need a newer Bash than the system Bash 3.2.

## Deploy

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Set dns_zone_name in terraform/terraform.tfvars.

DATADOG_API_KEY=<api-key> \
DATADOG_APP_KEY=<app-key> \
DATADOG_SITE=datadoghq.com \
  ./scripts/setup.sh
```

`setup.sh` validates prerequisites, provisions Terraform resources, builds and pushes ten images, initializes the application databases, deploys Kubernetes workloads, configures ALB and Route 53, installs metrics-server, and optionally installs/imports Datadog assets. It prints each application URL when complete.

Reconnect kubectl when needed:

```bash
aws eks update-kubeconfig --name sre-lab --region us-east-1
kubectl get pods -A
```

## Access applications

The configured domain is saved in `.lab-domain`.

```bash
open https://ecommerce.$(cat .lab-domain)
open https://banking.$(cat .lab-domain)
open https://food-delivery.$(cat .lab-domain)
open https://student-portal.$(cat .lab-domain)
open https://support-tickets.$(cat .lab-domain)
```

## Datadog

[datadog/helm-values.yaml](datadog/helm-values.yaml) enables APM, container logs, Kubernetes events, infrastructure metrics, and the Cluster Agent. Setup imports every JSON file under `datadog/dashboards/` and `datadog/monitors/` when both Datadog keys are supplied.

Establish a healthy baseline in each application dashboard and **SRE Lab Scenario Signals** before starting an exercise.

## Five incident scenarios

| Scenario | Main DevOps skill |
|---|---|
| [Bad Container Image Deployment](docs/incident-scenarios/01-bad-container-image.md) | ECR and Kubernetes Deployments |
| [Bad ConfigMap Rollout](docs/incident-scenarios/02-bad-configmap-rollout.md) | ConfigMaps and health probes |
| [OOMKilled and Resource Limits](docs/incident-scenarios/03-oomkilled-resource-limits.md) | Kubernetes resource management |
| [ALB and Ingress Routing Failure](docs/incident-scenarios/04-alb-ingress-routing.md) | ALB and Kubernetes networking |
| [High Application Latency](docs/incident-scenarios/05-high-application-latency.md) | Datadog APM and workload troubleshooting |

Student scenarios begin with symptoms and Datadog. Solutions and instructor triggers are in [Instructor Answer Keys](docs/incident-scenarios/instructor-answer-keys.md). Production-style STAR versions are in [DevOps STAR Scenarios](docs/devops-star-scenarios.md).

## Guides and PDFs

- [Student Guide](docs/student-guide.md)
- [Instructor Answer Keys](docs/incident-scenarios/instructor-answer-keys.md)
- [Scenario test checklist](docs/testing-the-lab.md)
- [Runbooks](docs/runbooks/)
- [SLO, SLA, and SLI](docs/slo-sla-sli.md)
- [Error budgets](docs/error-budget.md)
- [Combined scenario PDF](docs/pdf/sre-lab-devops-scenarios.pdf)
- [Individual scenario PDFs](docs/pdf/)

Markdown files under `docs/incident-scenarios/` are the source of truth. Regenerate PDFs with:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/generate-pdfs.ps1
```

## Destroy the environment

The lab costs money while running. Teardown deletes Ingress resources first so the controller can release the ALB, uninstalls Datadog and the controller, removes namespaces, and runs Terraform destroy.

```bash
./scripts/teardown.sh
```

Afterward, verify that the lab has no remaining ALBs, target groups, NAT Gateways, Elastic IPs, ECR repositories, or RDS instances in the AWS console.
