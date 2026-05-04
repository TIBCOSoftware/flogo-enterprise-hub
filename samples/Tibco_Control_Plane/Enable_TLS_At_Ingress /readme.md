# Configuring Ingress Controllers for Flogo Apps with Custom Certificates on TIBCO Platform


## Description

When a Flogo application is configured with custom TLS certificates and deployed on a Data Plane on TIBCO Control Plane, the application's secure endpoints may fail with errors. This happens because cloud providers terminate SSL at the load balancer level. After SSL termination, every call from the load balancer to the application pod is an HTTP call. However, since the Flogo app is configured with custom certificates, it expects an HTTPS call, causing the request to fail.

To resolve this, the ingress controller must be configured to make HTTPS requests to the backend application pod instead of plain HTTP.

This sample includes:
* A Flogo application (`self-signed-cert-app.flogo`) configured with self-signed TLS certificates.
* Self-signed certificates (`tls-multi.crt`, `tls-multi.key`) used by the application.
* Step-by-step instructions for configuring **Traefik**, **NGINX**, and **Kong** ingress controllers to forward HTTPS traffic to the application pod.


## The Problem

After deploying the Flogo app with custom certificates on TIBCO Control Plane, the Swagger UI for the application endpoint fails to load the API definition:

![Endpoints fail due to SSL termination at the load balancer](../images/Enable_TLS_At_Ingress%20/custom-cert-1.png)

The error indicates a fetch failure because the ingress controller is making an HTTP request to a pod that expects HTTPS. The fix is to configure the ingress controller to use HTTPS when communicating with the backend pod.


## Prerequisites

1. A Flogo application configured with custom TLS certificates, deployed on a Data Plane on TIBCO Control Plane.
2. Access to the Kubernetes cluster where the Data Plane is running.
3. `kubectl` configured to communicate with the cluster.
4. The TLS certificate and key files used in the Flogo application (e.g., `tls-multi.crt` and `tls-multi.key`).

---

## Configuring Traefik Ingress Controller

### Step 1: Create a Kubernetes TLS Secret

Create a Kubernetes secret from the same certificates used in the Flogo application. This secret will be referenced by the Traefik `ServersTransport` resource.

```bash
kubectl create secret tls app1-backend-ca \
  --cert=tls-multi.crt \
  --key=tls-multi.key \
  -n flogodpautomation-ns
```

Replace `flogodpautomation-ns` with the namespace where your application is deployed.

### Step 2: Create a ServersTransport CRD

Traefik uses a custom resource called `ServersTransport` to define how it communicates with backend services over TLS. This resource specifies the CA certificate to trust, the expected server name, and whether to skip certificate verification.

Create the following `ServersTransport` resource:

```yaml
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata:
  name: app1-transport
  namespace: flogodpautomation-ns
spec:
  insecureSkipVerify: true
  serverName: app1.flogodpautomation-ns.svc.cluster.local
  rootCAsSecrets:
    - app1-backend-ca
```

> **Note:** `insecureSkipVerify` is set to `true` here because the application uses self-signed certificates. For production deployments with certificates signed by a trusted CA, set this to `false`.

### Step 3: Add Annotations to the Application Service

Add the following two annotations to the Kubernetes Service of your Flogo application in the application's namespace:

```yaml
traefik.ingress.kubernetes.io/service.serversscheme: https
traefik.ingress.kubernetes.io/service.serverstransport: flogodpautomation-ns-app1-transport@kubernetescrd
```

* `service.serversscheme: https` tells Traefik to use HTTPS when forwarding requests to the backend pod.
* `service.serverstransport` references the `ServersTransport` resource created in Step 2. The format is `<namespace>-<serverstransport-name>@kubernetescrd`.

### Result

After applying the above configuration, the Traefik ingress controller makes secure HTTPS requests to the backend pod, and the application endpoints start working correctly:

![Endpoints working after configuring Traefik ingress controller](../images/Enable_TLS_At_Ingress%20/custom-cert-2.png)

---

## Configuring NGINX Ingress Controller

For NGINX ingress, the annotations must be added to the **Ingress resource** (not the Service).

Add the following annotations to the Ingress resource of your application:

```yaml
nginx.ingress.kubernetes.io/backend-protocol: HTTPS
nginx.ingress.kubernetes.io/proxy-ssl-secret: flogodpautomation-ns/app1-backend-ca
nginx.ingress.kubernetes.io/proxy-ssl-verify: "on"
```

* `backend-protocol: HTTPS` instructs the NGINX ingress controller to use HTTPS when connecting to the backend pod.
* `proxy-ssl-secret` specifies the TLS secret (created in Step 1) containing the CA certificate to verify the backend.
* `proxy-ssl-verify: "on"` enables SSL verification of the backend certificate.

---

## Configuring Kong Ingress Controller

For Kong ingress, the annotations must be added to the **Service** of the application pod.

Add the following annotations to the Kubernetes Service:

```yaml
konghq.com/protocol: "https"
konghq.com/tls-verify: "true"
konghq.com/ca-certificates-secrets: "app1-backend-ca"
```

* `protocol: "https"` tells Kong to use HTTPS when proxying requests to the backend pod.
* `tls-verify: "true"` enables TLS verification of the backend certificate. Set this to `"false"` for self-signed certificates.
* `ca-certificates-secrets` references the Kubernetes TLS secret containing the CA certificate to trust.

---

## Video Walkthrough

For a step-by-step video demonstration of this sample, watch the following tutorial:

[![Watch the video](https://img.youtube.com/vi/gE7OtBPUg4w/0.jpg)](https://www.youtube.com/watch?v=gE7OtBPUg4w)

---

## Help

Please visit our [TIBCO Flogo<sup>&trade;</sup> Extension for Visual Studio Code documentation](https://docs.tibco.com/products/tibco-flogo-extension-for-visual-studio-code-latest) and [App Build on TIBCO Control Plane documentation](https://docs.tibco.com/pub/platform-cp/latest/doc/html/Subsystems/flogo-capability/flogo-capability.htm#flogo-user-guide/app-builds.htm) for additional information.
