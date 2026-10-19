---
name: flogo-deploy
description: Deploy a TIBCO Flogo application to the TIBCO Platform. Provide the flogo app file path and the target dataplane name.
user-invocable: true
---

> **Preflight (only needed when deploying):** run `tibcop --version && tibcop list-profiles` first (see AGENT.md → Prerequisites and preflight, or `preflight.py --need deploy`). Every deploy command needs a profile name — use `TIBCOP_PROFILE` from `config.md` (create one with `tibcop add-profile --name "<profile>" --cpurl https://<SUBSCRIPTION>.<REGION>.my.tibco.com`, optional `--software-statement <software_statement>`; then `tibcop list-profiles`).

# Deploy a Flogo Application to the TIBCO Platform

This skill deploys a `.flogo` application file to a TIBCO Platform dataplane using the `tibcop` CLI.
Use the TIBCO Platform CLI profile configured for your environment (set in `config.md`).

## Required Inputs

- **Flogo app file**: Path to the `.flogo` file (check the apps folder named by `FLOGO_APPS_DIR` in `config.md` if not specified — resolved relative to `config.md` at `skills-library/.claude/skills/config.md`; the default `../../Flogo_Apps` points at `skills-library/Flogo_Apps/`, the same folder whether you opened the hub root or `skills-library`)
- **Dataplane name**: The target dataplane to deploy to
- **Profile**: The TIBCO Platform CLI profile to authenticate with

## Deployment Steps

Follow these steps in order:

### Step 1: Locate the Flogo app file

Find the `.flogo` file. If the user provides just an app name, look for it in the configured apps folder (e.g. `<FLOGO_APPS_DIR>/<appName>.flogo`) first, then search the project.

### Step 1b: Verify the app exposes its endpoints (prevents a post-deploy 503)

**Any app with a listening trigger** (REST, HTTP, WebSocket, MCP, A2A, … — anything that binds a port) must have those endpoints declared in the app's `metadata.endpoints`. The Platform build reads `metadata.endpoints` to generate the Kubernetes **Service ports**. If it is an **empty list**, the generated `values.yaml` gets `service.ports: []`, **no k8s Service is created**, and the app starts but has nothing behind its route — public calls then return an **nginx 503** and `tibcop flogo:list-app-endpoints` reports the k8s service "doesn't exist". **`fda cm` and unit tests do not catch this** — it is a packaging/platform concern, not flow validation — so an app that builds, validates, and passes all tests can still 503 after deploy.

Apps assembled via `fda` — especially ones scaffolded from a spec with `cas` — frequently ship with `metadata.endpoints: []`. **Before building, check it and backfill if empty:**

1. Inspect the app's `metadata.endpoints`. If it already lists every listening trigger, skip this step.
2. If empty (or missing a trigger), build one entry **per listening trigger** and write the array to a file, then apply it:
   ```shell
   fda sa any metadata.endpoints --jsonFile <endpoints.json> -f <PATH_TO_FLOGO_FILE>
   ```
   **Match the entry shape to the trigger type** — mirror a designer-authored endpoint of the same kind rather than forcing one template. The `spec` and `swagger` fields are **only for API triggers** that expose an OpenAPI/Swagger contract; port-only listeners have neither.

   - **Port-only listeners** — MCP, A2A, WebSocket, and any trigger that just binds a port with no OpenAPI/Swagger contract. Use the minimal shape, **no `spec`, no `swagger`**:
     ```json
     { "protocol": "<http | ws | ...>", "port": "<listen port>", "title": "<service name>", "type": "<public | private>" }
     ```
   - **API triggers** — REST / HTTP that publish an OpenAPI/Swagger contract. Add `spec` and `swagger` on top of the fields above:
     ```json
     {
       "protocol": "http",
       "port": "<listen port>",
       "title": "<service name>",
       "type": "<public | private>",
       "spec": { "name": "<app name>", "version": "<app version>" },
       "swagger": <Swagger 2.0 document>
     }
     ```
   Field notes:
   - `port` — read it from the trigger's own settings; never assume a number.
   - `title` — the service name shown in the CP UI "Service Name" column.
   - `type` — `public` or `private`; present on designer-authored endpoints, sets the CP visibility hint.
   - `swagger` (API triggers only) — source it from the trigger's `settings.swagger`, but that value **may be a `spec://<id>` reference rather than an inline document** (copying it verbatim produces the wrong endpoint shape). If it is a reference, resolve `<id>` in the app's `specs` map, base64-decode its `content`, and parse it. The resolved document may **already be Swagger 2.0** (has `swagger` / `basePath` / `definitions`) — use it as-is; convert only if it is OpenAPI 3.0 (`openapi` / `components`). Write the result to a file rather than inline — these documents are large.
3. Re-run `fda cm`, re-run the unit test suite, then build. After `generate-values-from-build` (Step 4), confirm the generated `values.yaml` has a **non-empty `service.ports`** before deploying.

### Step 2: List available Flogo versions on the dataplane

```shell
tibcop flogo:list-flogo-versions --profile <YOUR_PROFILE> --dataplane-name <DATAPLANE_NAME> --json
```

Pick the available `buildtypeTag` from the response (e.g. `2.25.9-b300`).

### Step 3: Create a build

```shell
tibcop flogo:create-build --profile <YOUR_PROFILE> --dataplane-name <DATAPLANE_NAME> --flogo-version <FLOGO_VERSION> --json <PATH_TO_FLOGO_FILE>
```

This will return a `buildId` and `status`. Wait for status `Success` before proceeding.

### Step 4: Generate values.yaml from the build

```shell
tibcop flogo:generate-values-from-build --profile <YOUR_PROFILE> --dataplane-name <DATAPLANE_NAME> --build-id <BUILD_ID> --output-dir <OUTPUT_DIR>
```

Use the same directory as the flogo file for the output. This generates a `values.yaml` with all the correct deployment configuration.

**Guard:** open the generated `values.yaml` and confirm `service.ports` is **non-empty** for any app that exposes a listening trigger. An empty `service.ports` means the app's `metadata.endpoints` was empty — go back to Step 1b and backfill it, then rebuild. Deploying with empty `service.ports` yields a running app that returns 503 on every call.

### Step 5: Set the app name in values.yaml

If the user specified a custom app name, update **both** of these fields in `values.yaml` before deploying:

- `appConfig.originalAppName` — the display name in the platform
- `fullnameOverride` — the runtime name (Kubernetes release name)

If you skip `fullnameOverride`, the app will appear as the generic `flogo-project` in the runtime even though `originalAppName` is correct.

### Step 6: Deploy using deploy-app-release with EULA acceptance

**Important**: Use `deploy-app-release` (NOT `deploy-app`) because it supports the required `--eula` flag. The `deploy-app` command will fail with a "TIBCO End User Agreement (EUA)" error.

```shell
tibcop flogo:deploy-app-release --profile <YOUR_PROFILE> --dataplane-name <DATAPLANE_NAME> --eula --json <PATH_TO_VALUES_YAML>
```

This will return an `appId` and success status.

### Step 7: Start the app (scale to 1 replica)

The app is deployed with 0 replicas by default. Scale it to 1 to start it:

```shell
tibcop flogo:scale-app --profile <YOUR_PROFILE> --dataplane-name <DATAPLANE_NAME> --app-id <APP_ID> --count 1 --json
```

This accepts the scale request asynchronously. The app will start running shortly after.

### Step 8: Report results

Provide the user with:
- The build ID
- The app ID
- The deployment and start status

## Troubleshooting

- **Authentication errors**: Ask the user to run `tibcop login --profile <YOUR_PROFILE>` to re-authenticate.
- **EUA error on deploy-app**: Switch to `deploy-app-release` with the `--eula` flag. The `deploy-app` command does not support EUA acceptance in its JSON payload.
- **Build failure**: Check the build status with `tibcop flogo:get-build-status --profile <YOUR_PROFILE> --dataplane-name <DATAPLANE_NAME> --build-id <BUILD_ID> --json`
- **No flogo versions**: The dataplane may not have a Flogo version provisioned. Use `tibcop flogo:provision-flogo-version` to provision one first.
- **Public calls return nginx 503 / `list-app-endpoints` says the k8s service "doesn't exist"**: The app's `metadata.endpoints` was empty, so `service.ports` is empty and no Service was created (see Step 1b). Fix the `.flogo` (backfill `metadata.endpoints`), rebuild to a new build, and **upgrade in place**: pull the app's current **live** values (`tibcop flogo:get-app-release-values --profile <YOUR_PROFILE> --dataplane-name <DATAPLANE_NAME> --app-id <APP_ID> --output-dir <DIR>`), change only `appConfig.buildId` to the new build and copy the new `service.ports` (and `serviceDescription`) in, then `tibcop flogo:update-app-release <values.yaml> --profile <YOUR_PROFILE> --dataplane-name <DATAPLANE_NAME> --app-id <APP_ID>`. Pass the same configured profile (and dataplane) that every other deploy command in this skill uses. Round-tripping the full live values preserves the app's endpoint visibility and secrets; a freshly generated `values.yaml` does not.
