---
name: flogo-design-assistant
description: A command line tool to create and modify TIBCO Flogo Integration Applications
user-invocable: true
---

The following tasks are available:

```shell
fda help                                                   
[Flogo Design] (INFO)    Creating folder:  .flogodesign/history/flogo-project/
[Flogo Design] (INFO)    Flogo Design History Enabled...
Usage: flogodesign-cli --file(-f) --type(-t) --json(-j) --configuration(-c) --history(-H)
file: Name of the Flogo file (default: flogo-project.flogo)
type: Type of the Flogo file (default: flow)
json: Output in JSON format (default: false)
config: Configuration file for Flogo Design CLI to use (You can also specify this as FLOGO_DESIGN_CONFIG_FILE environment variable)
history: Enable history for your Flogo Project (You can also specify this as FLOGO_DESIGN_ENABLE_HISTORY environment variable)
--- general ----
Task: version (v)                     Display version
Task: help (h)                        Show help
Task: show-design-config (sdc)        Show the current Flogo Design configuration
Task: export-design-config (edc)      Export the current Flogo Design configuration to a file
Task: list-flogo-projects (ls)        List all the flogo project files in the current directory
Task: analyze-vscode-extension (ave)  Checks for unknown imports in the VSCode Flogo Extension
Task: model-context-protocol (mcp)    Starts an MCP Sever for Flogo Development
--- process-development ----
Task: create-project (cp)             Create a new Flogo Project
Task: describe-project (dp)           Describe a Flogo Project
Task: describe-attributes (da)        Describes the attributes of a Flogo Item
Task: analyze-project (ap)            Checks for unknown imports in a Flogo Project
Task: create-flow (cf)                Create a new Flogo Flow
Task: remove-flow (rf)                Removes a Flogo Flow
Task: create-api-skeleton (cas)       Creates new Flogo Processes and Flows based on an API Definition
Task: create-mcp-skeleton (cms)       Creates new Flogo Processes and Flows for MCP, based on an API Definition
Task: create-activity (ca)            Add a Flogo Activity
Task: change-activity-type (cat)      Change the type of a Flogo Activity
Task: create-link (cl)                Create a link between two activities in a Flogo Flow
Task: remove-link (rl)                Removes a link between two activities in a Flogo Flow
Task: format-flow (ff)                Format a flow
Task: split-flogo-file (sff)          Splits a flogo file into project parts
Task: compose-flogo-file (cff)        Composes a flogo file from project parts
--- data-management ----
Task: create-spec (csp)               Create an API specification for a Flogo Project
Task: remove-spec (rsp)               Removes a spec from a Flogo Project
Task: create-schema (cs)              Create a schema for a Flogo Project
Task: remove-schema (rs)              Removes a schema from a Flogo Project
Task: create-app-property (cap)       Create an application property for a Flogo Project
Task: remove-app-property (rap)       Removes an application property from a Flogo Project
Task: set-attribute (sa)              Set attribute for a Flogo Object
--- connectivity ----
Task: create-trigger (ct)             Create a new Flogo Trigger
Task: remove-trigger (rt)             Removes a Flogo Trigger
Task: create-trigger-handler (cth)    Create a new Flogo Trigger Handler
Task: remove-trigger-handler (rth)    Removes a Flogo Trigger Handler
Task: create-connection (cc)          Create a new Flogo Connector
Task: remove-connection (rc)          Removes a Flogo Connection
Task: list-connection-types (lct)     List the possible connections types of a Flogo Project
Task: list-trigger-types (ltt)        List the possible triggers for a Flogo Flow
Task: list-activity-types (lat)       List the possible types of a Flogo Activities
Task: list-contributions (lco)        List the configured Flogo Contributions
Task: list-types (lt)                 List all the possible types currently know to Flogo Design CLI
--- testing ----
Task: validate (va)                   Validate the existence or non-existence of a Flogo Object
Task: create-test-file (ctf)          Creates a new Flogo test file
Task: describe-test-file (dt)         Describes a Flogo test file
Task: create-test-suite (cts)         Creates a new Flogo test suite in a test file
Task: create-test-case (ctc)          Creates a new Flogo test case in a test file
Task: create-assertion (cass)         Add an assertion to a test case
Task: add-test-case-to-suite (ats)    Adds a test case to a test suite in a test file
--- history ----
Task: show-history (sh)               Show the history of executed tasks, if no task is provided shows a table summary of all tasks
Task: restore-history (rhi)           Restores your flogo application to the version in the history
Task: script-history (sch)            Creates a script out of the historical commands
```

To get help on a specific task, run

```shell
fda help <task-name>
```

The parameters in between '<>' are inline parameters and flags are put in with two --
