# DevOps STAR Scenarios

These examples describe the five lab incidents as realistic production DevOps experiences. Each technical detail matches the lab implementation.

## 1. Bad Container Image Deployment

### Situation

A containerized application was running on Amazon EKS. During a deployment, new pods failed to start while the existing version continued serving traffic.

### Task

Determine why the new version could not deploy and restore a healthy rollout without disrupting healthy pods.

### Action

I checked the Deployment and pod status and found `ImagePullBackOff`. `kubectl describe pod` and Kubernetes events showed that the cluster could not retrieve the configured image. I compared the Deployment image with tags in Amazon ECR, found a nonexistent tag, corrected the reference, and monitored a new rollout.

### Result

The new pods became Ready and the Deployment completed. Image-tag validation was added to the delivery process.

### Natural spoken version

"An application on EKS had a rollout where new pods would not start, although the existing version still served traffic. I checked the rollout and saw `ImagePullBackOff`. Pod details and events showed that Kubernetes could not pull the configured image. I compared the Deployment tag with ECR and found that the tag did not exist. I corrected it, monitored the rollout until the pods became Ready, and verified the application. We then added image-tag validation before deployment."

## 2. Bad ConfigMap Rollout

### Situation

After a configuration change on EKS, new backend pods stopped becoming Ready while existing pods continued serving traffic.

### Task

Determine what changed and why only new pods failed.

### Action

I checked rollout status, pods, events, and logs. Probe failures occurred even though the application process started. Comparing the ConfigMap with the probes showed that `PORT` changed to 4001 while Kubernetes still checked 4000. I restored the ConfigMap and restarted the Deployment.

### Result

New pods became Ready, the rollout completed, and Datadog returned to baseline. Configuration validation was added to the deployment process.

### Natural spoken version

"After a configuration change, new EKS pods stopped becoming Ready while existing pods kept serving. Events showed readiness and liveness probe failures, but logs showed the process starting. I compared the ConfigMap and probe configuration and found that the application listened on 4001 while Kubernetes checked 4000. I restored the value, restarted the Deployment, validated external traffic, and confirmed recovery in Datadog."

## 3. OOMKilled

### Situation

A backend on EKS restarted unexpectedly and service stability degraded.

### Task

Determine whether the restarts came from application behavior, Kubernetes configuration, or infrastructure.

### Action

I started in Datadog and correlated memory data with restarts. Pod details showed `OOMKilled`. I compared observed consumption with the Deployment request and limit and found that the configured limit was below the workload requirement. I restored a measured resource baseline and redeployed.

### Result

Pods remained healthy, restarts stopped, and Datadog showed memory within the expected range. Similar workloads were reviewed using observed utilization.

### Natural spoken version

"A backend on EKS became unstable because pods restarted. Datadog showed memory and restart activity at the same time. Kubernetes reported `OOMKilled`, so I compared observed usage with the configured request and limit. The limit was below what the process needed. I restored a value based on measured usage, redeployed, and confirmed stable pods and memory in Datadog."

## 4. ALB and Kubernetes Ingress Routing

### Situation

An EKS application had healthy workloads, but users received HTTP 404 responses.

### Task

Determine where requests failed between the client and application.

### Action

I followed Route 53 to the ALB, Ingress, Service, and pods. DNS resolved, the ALB was reachable, and pods were Ready. Datadog APM showed backend `GET /` traces with 404 responses. The Ingress routed user traffic to the backend Service rather than the frontend. I restored the frontend Service and verified controller reconciliation.

### Result

External requests reached the frontend and the application became accessible. Traffic-path validation was added to deployment checks.

### Natural spoken version

"Users received 404 responses even though the EKS workloads were healthy. I traced Route 53, the ALB, Ingress, Service, and pods. Datadog showed that the backend was unexpectedly receiving `GET /`. The Ingress pointed to the backend instead of the frontend. I corrected it, waited for the controller to reconcile, tested externally, and confirmed the unexpected backend traffic stopped."

## 5. High Application Latency

### Situation

Users experienced increased response times from an application on Amazon EKS.

### Task

Determine whether latency came from AWS infrastructure, Kubernetes, or a particular workload.

### Action

I started with Datadog dashboards and APM. Slow traces identified the ecommerce backend. I checked its pods, CPU, memory, replicas, events, and logs, then correlated those results with trace duration. The workload had a response-delay setting enabled. I cleared it across the affected processes and generated traffic for validation.

### Result

Latency returned to baseline, traces improved, and pods remained healthy. Existing monitoring continued watching for recurrence.

### Natural spoken version

"Users reported slower responses from an EKS application. I used Datadog to scope the problem and APM identified the ecommerce backend. Kubernetes metrics and events were normal, while traces consistently showed added time in that workload. I found a response-delay setting enabled in the container, cleared it across the pods, generated traffic, and confirmed normal latency and healthy workloads in Datadog."
