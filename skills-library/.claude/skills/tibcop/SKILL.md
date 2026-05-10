---
name: tibco-platform-cli
description: A command line tool to manage the TIBCO Platform, including Flogo & Business Works Applications. This tool can list and deploy applications.
user-invocable: true
---

The following tasks are available:

```shell
tibcop --help
TIBCO Platform CLI

USAGE
  $ tibcop [COMMAND]

TOPICS
  bw5ce      TIBCO Platform Commands for Business Work 5 Container Edition (BW5)
  bwce       TIBCO Platform Commands for Business Work Container Edition (BWCE)
  flogo      TIBCO Platform Commands for Flogo
  plugins    Manage plugins of the TIBCO Platform CLI
  thub       TIBCO Platform Commands for the TIBCO Developer Hub
  tplatform  Commands for the TIBCO Platform

COMMANDS
  add-profile           Add profiles to your configuration
  ap                    Add profiles to your configuration
  autocomplete          Display autocomplete installation instructions.
  clean-all             Remove all profiles, configurations, CLI plugins and cache data
  di                    Display installation details
  display-installation  Display installation details
  help                  Display help for tibcop.
  init                  Initialize the CLI and create your default profile
  initialize            Initialize the CLI and create your default profile
  list-profiles         List all configured profiles
  login                 Relogin for a profile
  lp                    List all configured profiles
  plugins               List installed plugins.
  refresh-token         Refresh token for a profile
  remove-profile        Remove profiles from the configuration
  rp                    Remove profiles from the configuration
  rt                    Refresh token for a profile
  sp                    Change the default profile
  switch-profile        Change the default profile
  update-profile        Update profile in the configuration

```

To get help on a specific topic, run

```shell
tibcop <topic> --help, for example:

tibcop flogo --help            
TIBCO Platform Commands for Flogo

USAGE
  $ tibcop flogo:COMMAND

COMMANDS
  flogo:build-info                              Get detailed build info about FLOGO application build. The output contains the details like build OS,
                                                arch, base version, build time, etc. for the provided build Id
  flogo:capability-info                         Show FLOGO Capability info from the data plane
  flogo:create-build                            Create a TIBCO FLOGO application build. The command expects application (.flogo or .json) file, flogo
                                                base version and build tags as an input along with connector dependencies details
  flogo:delete-app                              Delete FLOGO app from the data plane
  flogo:delete-build                            Delete an application build. Please ensure the build to be deleted is not used by any application
  flogo:delete-connector                        Delete connector from the dataplane. Please ensure the connector to be deleted is not used in any
                                                application or build
  flogo:delete-flogo-version                    Delete provisioned FLOGO version from the dataplane. Please ensure the FLOGO version to be deleted is not
                                                used by any application or build
  flogo:delete-supplement                       Delete connector supplement from the dataplane. Please ensure the supplement to be deleted is not used in
                                                any application or build
  flogo:deploy-app                              Deploy or upgrade a flogo application using build Id. The API lets you provide override app properties,
                                                engine variables, resource limits for the pod, replicas or autoscaling configuration and network policy
                                                configurations while deploying or upgrading the app. An appId in payload is mandatory only for upgrading
                                                an existing application, otherwise it should be empty
  flogo:deploy-app-release                      Deploy or upgrade a FLOGO application helm chart using values.yaml. An appId inside values.yaml is
                                                mandatory for upgrading an existing application
  flogo:export-build                            Export flogo app build from the data plane
  flogo:generate-values-from-build              Generate values.yaml from an app build
  flogo:get-app-release-history                 Release history of an application deployment for an app Id. This is applicable only for FLOGO helm
                                                managed applications
  flogo:get-app-release-status                  Get FLOGO helm managed app release status from the data plane
  flogo:get-app-release-values                  Get FLOGO helm managed app release values from the data plane
  flogo:get-build-status                        Get FLOGO app build status from the data plane
  flogo:import-build                            Import FLOGO app build on the data plane
  flogo:list-app-endpoints                      List application endpoints for a FLOGO app. The API returns details about public/private endpoints and
                                                ingress configuration for the public endpoints
  flogo:list-app-instances                      Get list of application instances for provided app Id
  flogo:list-builds                             List FLOGO app builds from the data plane
  flogo:list-connectors                         List FLOGO connectors from the data plane
  flogo:list-flogo-versions                     List FLOGO versions provisioned in the data plane
  flogo:list-supplements                        List supplements from the data plane
  flogo:provision-connector                     Provision FLOGO connector on the data plane
  flogo:provision-flogo-version                 Provision FLOGO version on the data plane
  flogo:rollback-app-release                    Rollback an application helm chart release for an app Id to the specified revision
  flogo:scale-app                               Scale FLOGO app from the data plane
  flogo:update-app                              Update FLOGO application configuration for FLOGO provisioner managed application. The application will
                                                restart while applying the configuration
  flogo:update-app-autoscaling                  Create, modify or remove autoscaling configuration for a FLOGO Provisioner managed application. You can
                                                provide min/max replicas and CPU/memory thresholds for the HPA resource configuration
  flogo:update-app-endpoint-visibility          Make an application endpoint public or private for FLOGO provisioner managed apps. The API creates an
                                                ingress resource with provided inputs - ingress class name, FQDN, path prefix, etc
  flogo:update-app-release                      Update helm chart values for FLOGO application chart using values.yaml
  flogo:update-app-release-endpoint-visibility  Make an application endpoint public or private for helm managed apps. The API creates an ingress resource
                                                with provided inputs - ingress class name, FQDN, path prefix, etc
  flogo:upload-supplement                       Upload the supplement for a connector on the dataplane
```

To get help on a specific task, run

```shell
tibcop <topic>:<task> --help
```

> **Profile:** Always pass `--profile <YOUR_PROFILE>` to commands. Use the profile name configured for your TIBCO Platform environment (set up with `tibcop add-profile`). Set the default profile name in your project's `CLAUDE.md` so the agent uses it consistently.

If you get an authentication error, ask the user to run `tibcop login --profile <YOUR_PROFILE>` to re-authenticate.