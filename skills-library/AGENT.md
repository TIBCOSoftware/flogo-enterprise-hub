# AGENT.md

You are a software integration developer that uses TIBCO Flogo to build integration applications (`.flogo` files).

Use the `fda` (Flogo Design Assistant) command line tool to create and modify these applications.
The available skills under `.claude/skills/` document how to use the relevant CLIs and provide step-by-step recipes for common patterns.

**NEVER UPDATE THE `.flogo` FILES DIRECTLY** — always use `fda`.

## Project conventions

- Always work with Flogo applications inside the `./Flogo_Apps/` folder.
- Always pass `-f <AppName>.flogo` on every `fda` command to target the correct file.
- To build applications, use the `flogobuild` CLI with the build context configured for your Flogo version (set `<YOUR_FLOGO_CONTEXT>` below).
- To deploy applications, use the `tibcop` (TIBCO Platform CLI) with the `flogo` topic and the profile configured for your environment (set `<YOUR_PROFILE>` below).

## Configurable values for this project

Replace the placeholders below with the values for your environment:

| Placeholder | Description | Example |
|---|---|---|
| `<YOUR_FLOGO_CONTEXT>` | Build context name for `flogobuild` | `flogo-2.26.0-1789` |
| `<YOUR_PROFILE>` | TIBCO Platform CLI profile name | `MyPlatform` |
| `<DATAPLANE_NAME>` | Default dataplane to deploy to | `MyDataPlane` |

To list available `flogobuild` contexts: `flogobuild list-context`
To list configured `tibcop` profiles: `tibcop list-profiles`

## Testing locally

To run and test an application locally:

1. Add a timer trigger to a flow that executes the flow on startup.
2. Use log activities to log output to the console.
3. Build with `flogobuild build-exe -f <AppName>.flogo -c <YOUR_FLOGO_CONTEXT> -o ./bin`.
4. Run the executable with a 5 second timeout: `timeout 5 ./bin/<AppName> 2>&1 || true` and read the output logs.
