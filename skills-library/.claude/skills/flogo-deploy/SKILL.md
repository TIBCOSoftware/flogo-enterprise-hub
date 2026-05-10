---
name: flogo-deploy
description: Deploy a TIBCO Flogo application to the TIBCO Platform. Provide the flogo app file path and the target dataplane name.
user-invocable: true
---

# Deploy a Flogo Application to the TIBCO Platform

This skill deploys a `.flogo` application file to a TIBCO Platform dataplane using the `tibcop` CLI.
Use the TIBCO Platform CLI profile configured for your environment (e.g. set in your project's `CLAUDE.md` as `<YOUR_PROFILE>`).

## Required Inputs

- **Flogo app file**: Path to the `.flogo` file (check the Flogo apps folder if not specified, e.g. `./Flogo_Apps/`)
- **Dataplane name**: The target dataplane to deploy to
- **Profile**: The TIBCO Platform CLI profile to authenticate with

## Deployment Steps

Follow these steps in order:

### Step 1: Locate the Flogo app file

Find the `.flogo` file. If the user provides just an app name, look for it in the configured apps folder (e.g. `./Flogo_Apps/<appName>.flogo`) first, then search the project.

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
