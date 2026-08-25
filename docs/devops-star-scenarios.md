# DevOps STAR Scenarios

These examples turn the five lab incidents into realistic production DevOps narratives. Each example follows the STAR flow naturally without labeling its individual parts.

## 1. Bad Container Image Deployment

One of our applications was running on Amazon EKS when a release created new pods that could not start, while the existing version continued serving traffic. I needed to determine why the rollout was blocked and recover it without disrupting the healthy pods. I started with Datadog, where the stalled rollout and Kubernetes image-pull events identified the backend Deployment as the affected workload. Kubernetes showed `ImagePullBackOff`, and `kubectl describe pod` confirmed that the cluster could not retrieve the configured image. I compared the Deployment image with the tags available in its Amazon ECR repository and found that the requested tag did not exist. I rolled the Deployment back to its known working revision, monitored it until the new pods became Ready, verified the application, and confirmed that the Datadog signals recovered. Image-tag validation was then added to the delivery process.

### Natural spoken version

"One of our applications was running on EKS when a release produced new pods that would not start, although the existing version still served traffic. Datadog showed a stalled rollout and image-pull events, and Kubernetes reported `ImagePullBackOff`. Pod details showed that the cluster could not pull the configured image. I compared the Deployment tag with the tags in ECR and found that it did not exist. I rolled back to the working revision, monitored the rollout until the pods became Ready, tested the application, and confirmed recovery in Datadog. We then added image-tag validation before deployment."

### Brief example

"A release referenced image tag `v2.4.1`, but only `v2.4.0` existed in ECR. I confirmed `ImagePullBackOff`, rolled back, and added a tag-existence check to the pipeline."

## 2. Bad ConfigMap Rollout

An internal application was running on Amazon EKS when a configuration rollout caused new backend pods to stop becoming Ready while existing pods continued serving traffic. I needed to determine what changed and why the problem affected only the new pods. Datadog showed unavailable replicas, increasing restarts, probe-failure events, and errors in the backend logs. I checked the rollout, pod events, and application logs. The process started successfully, but the logs reported that it was listening on port 4001 while the readiness and liveness probes still checked port 4000. I compared the live ConfigMap with the Deployment probes, restored `PORT` to 4000, restarted the Deployment, and monitored it until all pods became Ready. External traffic succeeded and the Datadog monitors returned to normal. Configuration and health-probe validation was added to the deployment process.

### Natural spoken version

"After a configuration change to one of our internal applications, new EKS pods stopped becoming Ready while existing pods kept serving. Datadog showed unavailable replicas, restarts, and probe failures. The application logs showed that the process was listening on 4001, but Kubernetes was still checking 4000. I compared the ConfigMap with the probe configuration, restored the correct port, restarted the Deployment, and watched the rollout complete. I then tested the application and confirmed that the Datadog alerts recovered."

### Brief example

"A ConfigMap changed the application port to 4001 while the health probes still checked 4000. I aligned the port configuration, restarted the rollout, and verified that every pod became Ready."

## 3. OOMKilled and Resource Limits

An internal backend service on Amazon EKS became unstable because pods repeatedly restarted. I needed to determine whether the restarts came from application behavior, Kubernetes configuration, or the underlying infrastructure. Datadog correlated container restarts with memory usage approaching the configured limit for the backend Deployment. Kubernetes pod details showed `OOMKilled` and exit code 137 in the previous container state. I compared observed memory consumption with the Deployment request and limit and found that the limit had been reduced below what the Node.js process required. I restored the measured resource baseline, monitored the rollout, and verified that pods remained Ready, restart counts stopped increasing, and memory stayed below the limit in Datadog. Resource values for similar workloads were then reviewed using observed utilization rather than arbitrary limits.

### Natural spoken version

"One of our internal backend services on EKS became unstable because pods kept restarting. Datadog showed memory activity and container restarts at the same time. Kubernetes reported `OOMKilled`, so I compared actual usage with the configured request and limit. The limit had been reduced below what the process needed. I restored the measured resource baseline, monitored the rollout, and confirmed stable pods, no new restarts, and normal memory usage in Datadog."

### Brief example

"A backend was limited to 20 MiB even though it normally needed much more memory. I confirmed exit code 137 and `OOMKilled`, restored the measured limit, and stopped the restart loop."

## 4. ALB and Kubernetes Ingress Routing

One of our applications on Amazon EKS had healthy workloads, but users received HTTP 404 responses from its public URL. I needed to locate the failure across Route 53, the Application Load Balancer, Kubernetes Ingress, Services, endpoints, and pods. Datadog APM showed the backend unexpectedly receiving `GET /` requests and returning 404 while Kubernetes reported healthy frontend and backend pods. DNS resolved correctly and the ALB accepted connections. I reviewed the Ingress and found that the public route pointed to the backend Service on port 4000 instead of the frontend Service on port 80. I restored the frontend Service as the Ingress backend, waited for the AWS Load Balancer Controller to reconcile, tested the application externally, and confirmed that the unexpected backend 404 traces stopped in Datadog. Traffic-path validation was added to deployment checks.

### Natural spoken version

"Users received 404 responses from one of our applications even though the EKS workloads were healthy. Datadog showed that the backend was unexpectedly receiving `GET /`. I traced the request through Route 53, the ALB, Ingress, Services, endpoints, and pods. The Ingress pointed to the backend instead of the frontend. I restored the frontend route, waited for the controller to reconcile, tested the public URL, and confirmed that the backend 404 traces stopped in Datadog."

### Brief example

"The public `/` route targeted the backend on port 4000 instead of the frontend on port 80. I corrected the Ingress Service, waited for ALB reconciliation, and confirmed successful external requests."

## 5. High Application Latency

Users experienced increased response times from one of our applications running on Amazon EKS. I needed to determine whether the latency came from AWS infrastructure, Kubernetes, or a particular workload before making any changes. The service dashboard and high-p95 monitor showed elevated `trace.express.request` latency for the backend. In Datadog Trace Explorer, traces longer than two seconds identified the affected backend process, while Kubernetes CPU, memory, readiness, replicas, and restart metrics remained near baseline. I correlated the traces with workload logs and found that a response-delay setting was enabled in the container. I cleared the setting from each affected process, generated application traffic, and confirmed that p95 latency returned to baseline, traces improved, pods stayed healthy, and the Datadog monitor recovered. The existing latency monitoring remained in place for recurrence.

### Natural spoken version

"Users reported slower responses from one of our applications, so I started with Datadog instead of restarting pods. The dashboard and monitor showed higher p95 latency, and traces longer than two seconds identified the backend. Kubernetes CPU, memory, readiness, and restart metrics were normal, which narrowed the issue to workload behavior. I found a response-delay setting enabled in the container, cleared it from the affected processes, generated traffic, and confirmed normal traces, healthy pods, and monitor recovery."

### Brief example

"APM showed requests taking about three seconds while CPU, memory, and pod health remained normal. I found a 3000 ms application delay setting, cleared it, and confirmed that p95 latency returned to baseline."
