# **Flogo on TIBCO Control Plane — Deployment Samples**

Deploy **TIBCO Flogo®** integration applications to production on **Kubernetes** using the **TIBCO Platform**. These samples cover custom Docker image deployment for connector-specific runtime dependencies and secure TLS ingress configuration — essential patterns for cloud-native enterprise integration.

---

## Samples

| Sample | Description |
|--------|-------------|
| [Custom App Image — ActiveSpaces](./App_Deployment/Custom_App_Image/ActiveSpaces/) | Deploy a Flogo ActiveSpaces application using a custom Docker image with preinstalled ActiveSpaces and FTL runtime libraries |
| [Custom App Image — Oracle](./App_Deployment/Custom_App_Image/Oracle/) | Deploy a Flogo Oracle DB application using a custom Docker image with Oracle Instant Client libraries |
| [Enable TLS at Ingress](./Enable_TLS_At_Ingress/) | Configure ingress controllers (Traefik, NGINX, Kong) to forward HTTPS traffic to Flogo pods with custom TLS certificates |

---

## Common Deployment Pattern

All custom app image samples follow the same workflow:

1. **Build** the Flogo application locally (VS Code or `flogobuild`)
2. **Package** into a Docker image with connector-specific runtime libraries
3. **Push** the image to a container registry (e.g., AWS ECR)
4. **Import** the custom image into TIBCO Platform
5. **Deploy** to a Kubernetes-managed dataplane

---

## Prerequisites

- **Docker 20.10** or later
- **TIBCO Platform** access with a configured dataplane
- **Flogo build tools** (`flogobuild` or VS Code extension)
- **Container registry** access (AWS ECR, Docker Hub, etc.)
- **Connector-specific libraries:**
  - ActiveSpaces: TIBCO ActiveSpaces 4.10 + FTL runtime libraries
  - Oracle: Oracle Instant Client
- **TLS sample:** Self-signed or CA-signed certificates (`.crt`, `.key`, `.pem`)

---

## Feedback

Please contact us at [integration-pm@tibco.com](mailto:integration-pm@tibco.com) with any queries, feedback, or comments.

---

<sub>

`#TIBCOFlogo` `#Docker` `#Kubernetes` `#CloudNative` `#TIBCOPlatform` `#iPaaS` `#TLS` `#EnterpriseDeployment` `#ContainerOrchestration`

</sub>
