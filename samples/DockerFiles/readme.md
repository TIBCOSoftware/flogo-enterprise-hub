# Flogo Apps Docker File Examples

These are examples of running Flogo applications as Docker images in production mode.

## Directory Structure

### distros/
Contains Dockerfile examples for standard Flogo applications with no special connectors that require supplemental libraries.

**Files:**
- `Dockerfile.all-builders` - Consolidated builder stages for 5 Linux distributions (Debian, CentOS, Fedora, Amazon Linux 2023, RHEL UBI)
- `Dockerfile.all-runtimes` - Consolidated runtime stages for 7 Linux distributions (includes Alpine and Distroless)

### supplementConnectors/
Contains specialized Dockerfile examples for Flogo applications using connectors that require supplemental libraries.

#### EMS/
TIBCO Enterprise Message Service connector examples.
- `Dockerfile.all-builders` - Builder stages with EMS 10.3 library integration
- `Dockerfile.all-runtimes` - Runtime stages with EMS library distribution

#### IBM-MQ/
IBM MQ connector examples.
- `Dockerfile.all-builders` - Builder stages with IBM MQ client library integration
- `Dockerfile.all-runtimes` - Runtime stages with MQ library distribution

#### Oracle/
Oracle Database connector examples.
- `Dockerfile.all-builders` - Builder stages with Oracle Instant Client integration
- `Dockerfile.all-runtimes` - Runtime stages with Oracle client library distribution

#### SAP-Solutions/
SAP connector examples.
- `Dockerfile.all-builders` - Builder stages with SAP NetWeaver RFC SDK integration
- `Dockerfile.all-runtimes` - Runtime stages with SAP library distribution

## Usage

Each directory contains two main Dockerfile variants:
- **Dockerfile.all-builders**: Multi-stage builders for compiling Flogo applications across different Linux distributions
- **Dockerfile.all-runtimes**: Multi-stage runtimes for deploying compiled Flogo applications

### Building Images

Use build arguments to select your target distribution:

```bash
# Build with specific builder
docker build --target builder-debian -t flogo-builder:debian -f Dockerfile.all-builders .

# Build with specific runtime
docker build --build-arg RUNTIME_BASE=alpine -t flogo-app:alpine -f Dockerfile.all-runtimes .
```

### Running Flogo Applications with License

Flogo Enterprise applications require a license file to run in production mode. You can supply the license file to Docker containers using volume mounts and environment variables.

**Example:**

```bash
docker run -it -p 9999:9999 \
  -e TIB_ACTIVATION=/build/license/92-Days-10-24-FLOGO_S_ANY_LOCAL_Eval-DoNotREDISTRIBUTE.bin \
  -v "/home/rgoyal/prod-docker-images/prod-docker-images/":/build/license/ \
  flogo-app:debian
```

**Explanation:**
- `-p 9999:9999`: Exposes the application port (adjust to your app's port)
- `-e TIB_ACTIVATION=<path>`: Environment variable pointing to the license file path inside the container
- `-v <host-path>:<container-path>`: Volume mount that maps your host directory containing the license file to a path inside the container
- The license file path in `TIB_ACTIVATION` must match the mounted volume path inside the container

This approach allows you to manage license files externally without embedding them in Docker images, making it easier to update licenses and maintain security.

## Requirements

- Docker 20.10 or later
- Flogo Enterprise build tools (flogobuild, .vsix extensions)
- For connector-specific builds: supplemental libraries (EMS, MQ, Oracle, SAP)

## Builder/Runtime Compatibility Matrix

### AMD64 - Standard Flogo Apps (distros/)

| **Builder Distro** ↓ / **Runtime Distro** → | Debian/Ubuntu | Alpine | CentOS | Fedora | Amazon Linux 2/2023 | Amazon Graviton | GCP Container OS | Distroless | RedHat UBI |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **Debian/Ubuntu** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Alpine** | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **CentOS** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Fedora** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Amazon Linux 2/2023** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Amazon Graviton** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **RedHat UBI** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

> **Note:** Alpine builders are not supported for standard Flogo apps due to musl libc compatibility issues.

### ARM64 - Standard Flogo Apps

| **Builder Distro** ↓ / **Runtime Distro** → | Debian/Ubuntu | Alpine | CentOS | Fedora | Amazon Linux 2023 | Amazon Graviton | GCP Container OS | Distroless | RedHat UBI |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **Debian/Ubuntu** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

> **Note:** Flogo apps with EMS connectors, IBM MQ, and SAP Solutions are not supported for ARM64 due to unavailability of supplemental libraries for ARM64 architecture.

### EMS Connector Apps

| **Builder Distro** ↓ / **Runtime Distro** → | Debian/Ubuntu | Alpine | CentOS | Fedora | Amazon Linux 2023 | Amazon Graviton | GCP Container OS | Distroless | RedHat UBI |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **Debian/Ubuntu** | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Alpine** | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **CentOS** | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Fedora** | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Amazon Linux 2/2023** | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **RedHat UBI** | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |

> **Note:** EMS builders are limited to Debian, Fedora, and Amazon Linux due to EMS library compatibility.

### Oracle Connector Apps

| **Builder Distro** ↓ / **Runtime Distro** → | Debian/Ubuntu | Alpine | CentOS | Fedora | Amazon Linux 2023 | Amazon Graviton | GCP Container OS | Distroless | RedHat UBI |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **Debian/Ubuntu** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| **Alpine** | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **CentOS** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| **Fedora** | ❌* | ❌* | ❌* | ✅ | ❌* | ❌* | ❌* | ❌ | ❌* |
| **Amazon Linux 2/2023** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| **RedHat UBI** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |

> **Note:** *Fedora builder has glibc version mismatches with other distros. Distroless runtime not supported for Oracle apps.

### SAP Solutions Apps

| **Builder Distro** ↓ / **Runtime Distro** → | Debian/Ubuntu | Alpine | CentOS | Fedora | Amazon Linux 2023 | Amazon Graviton | GCP Container OS | Distroless | RedHat UBI |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **Debian/Ubuntu** | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| **Alpine** | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **CentOS** | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| **Fedora** | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| **Amazon Linux 2/2023** | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| **RedHat UBI** | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |

> **Note:** SAP apps do not support Alpine or Distroless runtimes due to library dependencies.

### IBM MQ Connector Apps

| **Builder Distro** ↓ / **Runtime Distro** → | Debian/Ubuntu | Alpine | CentOS | Fedora | Amazon Linux 2023 | Amazon Graviton | GCP Container OS | Distroless | RedHat UBI |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **Debian/Ubuntu** | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| **Alpine** | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **CentOS** | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| **Fedora** | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| **Amazon Linux 2/2023** | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| **RedHat UBI** | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |

> **Note:** IBM MQ apps do not support Alpine or Distroless runtimes due to MQ client library requirements.
