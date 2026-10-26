---
name: flogobuild
description: A command line tool to build executables for TIBCO Flogo Integration Applications
user-invocable: true
---

> **Preflight (only needed when building):** run `flogobuild version && flogobuild list-context && go version` first (see AGENT.md → Prerequisites and preflight, or `preflight.py --need build`). Designing apps doesn't need any of this. `flogobuild` (Flogo App Build CLI) is downloaded from the [TIBCO downloads page](https://www.tibco.com/downloads/11810) (not bundled in the VS Code extension), and building Flogo apps requires the Go runtime ([go.dev/dl](https://go.dev/dl/)); if no context is listed, create one with `flogobuild create-context -n <name-without-dots> -v <path-to-vsix> --set-default`.


```
flogobuild                  
Command-line utility for building executable and Docker image for TIBCO Flogo® applications

Usage:
flogobuild [command]

Available Commands:
build-docker-image   Build Flogo application Docker image
build-exe            Build Flogo application executable
build-tp-deployment  Build TIBCO Platform deployment zip for the Flogo application
create-context       Create context for building and packaging Flogo applications
delete-context       Delete existing context
help                 Help about any command
list-context         List available contexts
package-docker-image Package existing Linux based Flogo application executable as docker image
set-default-context  Set one of the configured context as default for building and packaging Flogo applications
test-app             Test Flogo application
version              Print the version

Flags:
--debug     Enable debug mode for detailed logging
-h, --help      help for flogobuild
--verbose   Enable verbose mode for additional output

Use "flogobuild [command] --help" for more information about a command.
```

To get help on a specific command run:

```
flogobuild [command] -h
```

To build an executable for testing run:

```
flogobuild build-exe -h                
Build Flogo application executable

Usage:
flogobuild build-exe [flags]

Flags:
-f, --app-json-file string      Path for FLOGO application file(.json/.flogo)
-c, --context-name string       Name of the context to used for building app. If not provided, default context will be used
-n, --exe-name string           Name of the executable file. If not provided, app name will be used as executable file name
-h, --help                      help for build-exe
-o, --output-directory string   Directory where executable file to be created. If not provided, executable will be created in the current directory
-p, --platform string           Platform(OS) type for the app executable. Specify value in GOOS/GOARCH format. e.g ["linux/amd64","windows/amd64","darwin/amd64","darwin/arm64"]. If not provided, app will be build for current platform where CLI is running. Refer https://go.dev/doc/install/source#environment for supported platforms.

Global Flags:
--debug     Enable debug mode for detailed logging
--verbose   Enable verbose mode for additional output
```

**Where the executable lands (differs from the help text).** `build-exe` appends the *directory part of a relative app path* to the output directory: the exe goes to `<-o, or the current directory>/<dir of the -f path>/`. So `-f ../apps/App.flogo` with no `-o` drops the exe next to the `.flogo` (as does an absolute `-f` with no `-o`), and `-f apps/App.flogo -o bin` fails with `open bin\apps\App.exe: The system cannot find the path specified`. Use one of these forms to put it exactly in the output folder:

```bash
# A (portable: flogobuild 1.0.6 and 1.1.x): run from the folder that holds the .flogo, pass just the file name.
# The subshell ( ... ) keeps your current directory unchanged for the commands that follow.
( cd <FLOGO_APPS_DIR> && flogobuild build-exe -f <AppName>.flogo -c <FLOGOBUILD_CONTEXT_NAME> -o ../bin )

# B (flogobuild 1.1.x only, where -a exists): absolute app path with -a and absolute output directory (Windows paths on Windows)
flogobuild build-exe -a "<abs-path>/<AppName>.flogo" -c <FLOGOBUILD_CONTEXT_NAME> -o "<abs-path>/bin"
```

Then check the `Executable file created at …` line in the output.

> **Build context:** Use the build context configured for your Flogo version. List available contexts with `flogobuild list-context`. The context name typically follows the pattern `flogo-<version>-<build>` (e.g. `flogo-2.26.0-1789`). Set this as `FLOGOBUILD_CONTEXT_NAME` in `config.md` so the agent uses the right one.