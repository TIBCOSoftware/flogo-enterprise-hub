# Google Connection — Service Account Key Override


## Description

This example demonstrates how to **override the Google Connection Service Account Key** at runtime using app properties in TIBCO Flogo Extension for Visual Studio Code.

By default, the Service Account JSON key is embedded in the Flogo app at design time via a file selector. This feature adds support for configuring the key as an **app property** and overriding it at runtime — without rebuilding the app — using any of the following formats:

* **Base64-encoded** Service Account Key in Base64-encoded format
* **Raw JSON** Service Account Key value in JSON-escaped format
* **File path** starting with `file://` followed by the path to the Service Account Key file
* **Kubernetes (K8s) Secret** referenced via the deployment's values.yaml file

> **Encryption note:** In Flogo 2x, the `Encrypt Secret` flag is visible but encryption is not applied — the app runs normally without errors.


## Prerequisites

1. The application is compatible with Flogo Extension for Visual Studio Code version 2.26.4+.

2. A Google Cloud Platform (GCP) account with an active project.

3. A **Service Account** with the required IAM roles (e.g., `Storage Admin` for GCS) and its **JSON key file** downloaded from GCP Console.

4. TIBCO Flogo Extension for Visual Studio Code installed and a Flogo app with Google Connection configured (e.g., `GCS-CRUD-App`).

5. For **Kubernetes** override: a running Kubernetes cluster (e.g., Minikube) with `kubectl` configured, and the Flogo app binary built as a Docker image.


## Google Connection Service Account Key as an App Property

Instead of embedding the key at design time using the file selector, configure it as an **app property** that can be overridden at runtime.

1. Open your Flogo app in VS Code.

2. Go to **CONNECTIONS** and open your Google Connection.

![Open Google Connection](../../../images/GoogleConnection/overrideSAkey/1.png)

3. In the **Service Account Key** field, browse and select the key.

4. On the right side of the **Service Account Key** field, the property name is shown (e.g., `GoogleConnection.googleconn.Service_Account_Key`) — you will use this name when overriding at runtime.

![App Property name input](../../../images/GoogleConnection/overrideSAkey/2.png)

5. Click **Save** to save the connection.

> **Note:** The Service Account key can still be set at design time in the property value. The runtime override via `FLOGO_APP_PROPS_JSON` takes precedence over the design-time value.

> **Backward compatibility:** Existing Google connections using the old file selector method continue to work without any changes after upgrading. The **"App Property"** is visible for existing connections.


## Override Methods

You can directly pass the Base64-encoded value or JSON key file path to the app property by setting an environment variable when starting the app.

**Example:**

```
GoogleConnection_googleconn_Service_Account_Key=<Base64_encoded_value_OR_JSON_key_file_path_here>, FLOGO_APP_PROPS_ENV=auto
```

OR

Use the `FLOGO_APP_PROPS_JSON` environment variable when starting the app to supply or replace the Service Account Key at runtime. The variable accepts a JSON object where you can specify the Base64-encoded value, JSON-escaped value, or key JSON file path.

**Example:**

```
FLOGO_APP_PROPS_JSON=<path-to-file>
```

---

### Method 1 — Base64-encoded Value

Run your app by directly passing the Base64-encoded value to the app property.

**Step 1:** Convert the JSON key file to a Base64-encoded value.

**Step 2:** To run the app, go to **Configure and Run Action**, then select **Environment variables** and enter the following value to override.

**Example:**

```
GoogleConnection_googleconn_Service_Account_Key=<Base64_encoded_value_here>, FLOGO_APP_PROPS_ENV=auto
```


![Base64 override app running](../../../images/GoogleConnection/overrideSAkey/3.png)
![Base64 override app running](../../../images/GoogleConnection/overrideSAkey/4.png)

---

### Method 2 — File Path (file://)

Reference a JSON key file on disk using the `file://` prefix. The app reads the key directly from the specified file at startup.
To run the app, go to **Configure and Run Action**, then select **Environment variables** and enter the following value to override.

**Example:**

```
GoogleConnection_googleconn_Service_Account_Key=file:///C:/secrets/gcs-key.json, FLOGO_APP_PROPS_ENV=auto
```


> **Note:** The path must be absolute and the file must be readable by the Flogo app process at runtime. 

![File path override app running](../../../images/GoogleConnection/overrideSAkey/5.png)

---

### Method 3 — Using a Custom Environment File

Create a JSON file containing all property overrides and pass the **file path** directly to `FLOGO_APP_PROPS_JSON`. This is the recommended approach — it avoids exposing secrets in shell history and supports all three key formats in a single file.

**Sample env file (`gcs-override.env`):**

The env file must include `"FLOGO_APP_PROPS_ENV": "auto"` to enable app property override from the file. You can include all three formats simultaneously for different connections:

```json
{
    "FLOGO_APP_PROPS_ENV": "auto",
    "GoogleConnection.gglFile.Service_Account_Key": "file://C:/path/to/key.json",
    "GoogleConnection.gglJSON.Service_Account_Key": "{\n  \"type\": \"service_account\",\n  \"project_id\": \"project\",\n  \"private_key_id\": \"5d23...\",\n  \"private_key\": \"-----BEGIN PRIVATE KEY-----\\nMIIEvQIBADA...\\n-----END PRIVATE KEY-----\\n\",\n  \"client_email\": \"email@client.iam.gserviceaccount.com\",\n  \"client_id\": \"10164805678964129\",\n  \"auth_uri\": \"https://accounts.google.com/o/oauth2/auth\",\n  \"token_uri\": \"https://oauth2.googleapis.com/token\"\n}\n",
    "GoogleConnection.gglBase64.Service_Account_Key": "eyJ0eXBlIjoic2VydmljZV9hY2NvdW50IInRjaS1mbG9nbyIs..."
}
```

> **Key notes:**
> - `"FLOGO_APP_PROPS_ENV": "auto"` is **required** — it tells the Flogo runtime to read properties from the file.
> - Each property name (e.g., `GoogleConnection.gglFile.Service_Account_Key`) must match the app property name configured in the connection settings.
> - All three formats (file path, raw JSON, Base64) can coexist in the same env file for different connections.
> - File path uses `file://` (two slashes) for Windows paths.

**Run the app by passing the file path directly:**

Go to **Configure and Run Action**, then select **Environment variables** and enter the following value to override.

**Example:**

```
FLOGO_APP_PROPS_JSON=<path-to-env-file>
```

> **Important:** `FLOGO_APP_PROPS_JSON` accepts a **file path** (pointing to the env file).

![Custom env file override app running](../../../images/GoogleConnection/overrideSAkey/6.png)

---

### Method 4 — Kubernetes (K8s) Secret

For Kubernetes deployments, store the Service Account Key as a K8s Secret and reference it in the deployment's values.yaml configuration.

#### Step 1 — Create a Flogo app with a Google connection attached to it

Provide an invalid Service Account Key in the connection (e.g., create an app with the Google Cloud Storage connector).

#### Step 2 — Create the Kubernetes Secret in the same namespace where you are deploying the app on TIBCO Platform (TP)

Create a secret from your JSON key file:

```bash
kubectl create secret generic gcs-sa-key \
  --from-file="C:\path\to\service-account-key.json" \
  --namespace=flogotestdp-ns
```

Verify the secret was created:

```bash
kubectl get secrets gcs-sa-key -n flogotestdp-ns
```

#### Step 3 — Deploy the app on TP using the Helm method. Start and set Endpoint Visibility.

For a Helm-deployed app, you need to edit the values.yaml file to reference the secret.

#### Step 4 — Update the deployed app's values.yaml and apply changes

  a. Update the appProperties values in the values.yaml file.
  b. Edit the volumes.
  c. Edit the volumeMounts.

Here is a sample values.yaml:

```yaml
affinity: {}
appConfig:
  appId: d879r1ddgg4s739hovs0
  appVersion: 1.0.0
  buildId: 72d0ad2dbca844a2b43ab62262709e97
  connectors: Google Cloud Storage-Google Sheets-Google Connection-General
  customFQImage: ""
  flogoAppMetrics: true
  flogoAppPropsEnv: auto
  flogoBaseImageTag: 2.26.4-b483
  flogoBuildTypeTag: 2.26.4-b483
  flogoExposeSwaggerEp: true
  flogoHttpServicePort: 7777
  lastUpdated: "1779343213"
  originalAppName: google_conn_tests
  tags: ""
  workloadType: user-app
appInit:
  resources:
    limits:
      cpu: 200m
      memory: 400Mi
    requests:
      cpu: 100m
      memory: 100Mi
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop:
      - ALL
      - CAP_NET_RAW
    readOnlyRootFilesystem: true
appProps:
  GoogleConnection.googleconn.Service_Account_Key: file:///etc/gcp/key.json
appSecrets: {}
auditSafe:
  enabled: true
autoscaling:
  behavior: {}
  customMetrics: []
  enabled: false
  maxReplicas: 3
  minReplicas: 1
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80
crds: []
deploymentAnnotations: {}
deploymentLabels: {}
dpConfig:
  activationServiceUrl: ""
  capabilityDefaultNamespace: k8s-auto-dp1ns
  capabilityInstanceId: d85hkgp70q0s73em99dg
  capabilityVersion: 1.18.0
  customCertSecretName: ""
  dataplaneId: d81cvajkktgs73e2n0t0
  helmRepoAlias: tibco-platform-public
  licenseMountPath: /home/flogo/license
  licenseSecretName: cp-license-file-secret
  licenseSecretPath: /home/flogo/license/license-file.bin
enableTmpVolume: true
engineProps:
  FLOGO_LOG_LEVEL: ERROR
  FLOGO_OTEL_TRACE: "false"
engineSecrets: {}
executionHistory:
  enabled: false
flogoapp:
  envFrom:
    configMapRef: []
    secretRef: []
  envs: []
  lifecycle: {}
  livenessProbe:
    failureThreshold: 3
    httpGet:
      path: /ping
      port: 7777
      scheme: HTTP
    initialDelaySeconds: 10
    periodSeconds: 6
    successThreshold: 1
    timeoutSeconds: 5
  readinessProbe:
    failureThreshold: 3
    httpGet:
      path: /ping
      port: 7777
      scheme: HTTP
    initialDelaySeconds: 10
    periodSeconds: 5
    successThreshold: 1
    timeoutSeconds: 5
  resources:
    limits:
      cpu: 500m
      memory: 1024Mi
    requests:
      cpu: 250m
      memory: 512Mi
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop:
      - ALL
      - CAP_NET_RAW
    readOnlyRootFilesystem: false
  startupProbe:
    failureThreshold: 50
    httpGet:
      path: /ping
      port: 7777
      scheme: HTTP
    periodSeconds: 6
    successThreshold: 1
    timeoutSeconds: 5
  volumeMounts:
  - mountPath: /etc/gcp
    name: mygconnvol
    readOnly: true
fluentBit:
  configMapName: otel-config-flogo
  enabled: true
  lifecycle: {}
  livenessProbe:
    failureThreshold: 3
    httpGet:
      path: /api/v1/uptime
      port: 2020
      scheme: HTTP
    initialDelaySeconds: 10
    periodSeconds: 10
    successThreshold: 1
    timeoutSeconds: 5
  resources:
    limits:
      cpu: 100m
      memory: 100Mi
    requests:
      cpu: 10m
      memory: 10Mi
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop:
      - ALL
      - CAP_NET_RAW
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    runAsUser: 1000
fullnameOverride: google-conn-tests-helm
gateway:
  annotations: {}
  controllerName: ""
  enabled: false
  name: ""
  namespace: ""
  resourceInstanceName: ""
  rules:
  - host: example.com
    paths:
    - customCRDConfig: {}
      filters: []
      path: /
      pathType: PathPrefix
      port: 9999
      serviceDescription: ""
      serviceDiscoverable: true
  sectionName: ""
image:
  appInitImageName: tp-flogo-app-init
  appInitImageTag: "72"
  flogoBaseImageName: tp-flogo-app-base
  fluentBitImageName: common-fluentbit
  fluentBitImageTag: 5.0.5
  pullPolicy: IfNotPresent
  repository: csgprdusw2reposaas.jfrog.io/tibco-platform-docker-dev/
imagePullSecrets:
- name: d81cvajkktgs73e2n0t0
ingress:
  annotations: {}
  className: traefik
  controllerName: traefik
  enabled: true
  resourceInstanceName: ""
  rules:
  - host: apps-traefik.cp1-my.localhost.dataplanes.pro
    paths:
    - path: /tibco/apps/d879r1ddgg4s739hovs0/ReceiveHTTPMessage
      pathType: Prefix
      port: 9999
      serviceDescription: '{"services":[{"specURL":"https://apps-traefik.cp1-my.localhost.dataplanes.pro/tibco/apps/d879r1ddgg4s739hovs0/ReceiveHTTPMessage/api/v2/swagger.json","serviceURL":"https://apps-traefik.cp1-my.localhost.dataplanes.pro/tibco/apps/d879r1ddgg4s739hovs0/ReceiveHTTPMessage","title":"google_conn_tests","description":"google_conn_tests
        service"}]}'
      serviceDiscoverable: true
  tls: []
initContainers: []
nameOverride: ""
networkPolicy:
  clusterEgress: enable
  databaseEgress: enable
  internetAll: enable
  internetWeb: enable
  msgInfra: enable
  proxyEgress: enable
  userApps: enable
nodeSelector: {}
otel:
  metrics:
    enabled: true
  traces:
    enabled: true
podAnnotations: {}
podLabels: {}
podSecurityContext:
  fsGroup: 1000
  fsGroupChangePolicy: Always
  runAsGroup: 1000
  runAsNonRoot: true
  runAsUser: 1000
  seccompProfile:
    type: RuntimeDefault
pvc: []
replicaCount: 1
service:
  annotations: {}
  customhealthCheckPolicy: {}
  labels: {}
  ports:
  - port: "9999"
    targetPort: "9999"
  serviceDescription: '{"services":[{"specURL":"http://google-conn-tests.k8s-auto-dp1ns.svc.cluster.local:9999/api/v2/swagger.json","serviceURL":"http://google-conn-tests.k8s-auto-dp1ns.svc.cluster.local:9999","title":"ReceiveHTTPMessage","description":"ReceiveHTTPMessage
    service"}]}'
  serviceDiscoverable: true
  type: ClusterIP
serviceAccountName: ""
serviceMesh:
  enabled: false
sidecars: []
strategy:
  type: RollingUpdate
tolerations: []
topologySpreadConstraints: []
volumes:
- name: mygconnvol
  secret:
    optional: false
    secretName: gcs-sa-key
workload: deployment

```

#### Step 5 — Hit the endpoint and search for log

Expected log:

```
INFO [flogo] - Properties will be resolved with the 'env' resolver
```


## Understanding the Configuration

### All Three Override Formats in a Single Run

The same app can be tested with all three override formats by overriding the env file with the env var `FLOGO_APP_PROPS_JSON=<path-to-file>` — no rebuild required:

```json
{
    "FLOGO_APP_PROPS_ENV": "auto",
    "GoogleConnection.gglFile.Service_Account_Key": "file://C:/path/to/key.json",
    "GoogleConnection.gglJSON.Service_Account_Key": "{\n  \"type\": \"service_account\",\n  \"project_id\": \"tci-flogo\",\n  \"private_key_id\": \"5d1b86d3...\",\n  \"private_key\": \"-----BEGIN PRIVATE KEY-----\\nMIIEvQIBADA...\\n-----END PRIVATE KEY-----\\n\",\n  \"client_email\": \"flogopubsub@tci-flogo.iam.gserviceaccount.com\",\n  \"client_id\": \"101648056839578964129\",\n  \"auth_uri\": \"https://accounts.google.com/o/oauth2/auth\",\n  \"token_uri\": \"https://oauth2.googleapis.com/token\"\n}\n",
    "GoogleConnection.gglBase64.Service_Account_Key": "eyJ0eXBlIjoic2VydmljZV9hY2NvdW50IiwicHJvamVjdF9pZCI6InRjaS1mbG9nbyIs..."
}
```

### Multi-Connector App

If your app uses both Google Cloud Storage and Google Sheets flows, the same overridden key works for all Google connections that share the same property name:


## Verify the Override is Working

After starting the app with an override, confirm it works by:

1. **Hitting the GCS endpoint:**

    A successful response (GCS bucket/object operations completed) confirms the overridden key authenticated correctly with Google Cloud.

2. **Checking app logs** — no authentication errors should appear:

    ```
    INFO [flogo] - Properties will be resolved with the 'env' resolver
    ```

    If you see `oauth2: cannot fetch token: 400 Bad Request Response: {"error":"invalid_grant","error_description":"Invalid JWT Signature."}`, the key override value is invalid.

![Successful override verification](../../../images/GoogleConnection/overrideSAkey/7.png)
![Successful override verification](../../../images/GoogleConnection/overrideSAkey/8.png)


## Troubleshooting

* **App fails with "invalid base64 encoded service account key"**  
  The Base64-encoded value is invalid. Re-encode the key file and verify that the full value is passed without line breaks.

* **"The system cannot find the path specified" error when using `file://` path**  
  The file path is incorrect or the file does not exist. Verify that the correct path is provided and the file is present at the given location.

* **K8s pod starts but no clear error when secret is wrong**  
  Check that the secret is created in the same namespace where you have deployed the app, and verify that the correct name is mentioned in the values.yaml file.

* **Key override not being applied (design-time key still used)**  
  Verify that the connection has **"App Property"** enabled (not using the old file selector). Check that the property name in `FLOGO_APP_PROPS_JSON` exactly matches the name shown in the connection settings or in App Properties.

* **`FLOGO_APP_PROPS_JSON` parsing error**  
  The JSON is malformed. Common causes: unescaped double quotes, missing commas, or trailing newlines. Validate with `echo $FLOGO_APP_PROPS_JSON | python3 -m json.tool`.


## Notes and Links

* The `FLOGO_APP_PROPS_JSON` environment variable is the recommended approach for runtime override — no app rebuild is required.

* When using `file://`, the file is read once at startup. 

* For multi-connector apps (GCS + Google Sheets), each connection's property name must be included separately in `FLOGO_APP_PROPS_JSON` if they use different property names.

* For more information on Creating Google Connection, refer to the 
[Creating Google Connection documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/google-cloud-storage/creating-a-google-connection.htm?TocPath=Connectors%2520User%2520Guide%257CSupported%2520Flogo%2520Connectors%257CGoogle%2520Cloud%2520Storage%257CCreating%2520a%2520Google%2520Connection%257C_____0) and for Google Connection Details, refer to the [Google Connection Details documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/google-cloud-storage/google-connection-details.htm?TocPath=Connectors%2520User%2520Guide%257CSupported%2520Flogo%2520Connectors%257CGoogle%2520Cloud%2520Storage%257CCreating%2520a%2520Google%2520Connection%257C_____1)  .
