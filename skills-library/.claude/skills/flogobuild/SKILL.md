---
name: flogobuild
description: A command line tool to build executables for TIBCO Flogo Integration Applications
user-invocable: true
---


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

> **Build context:** Use the build context configured for your Flogo version. List available contexts with `flogobuild list-context`. The context name typically follows the pattern `flogo-<version>-<build>` (e.g. `flogo-2.26.0-1789`). Set this in your project's `CLAUDE.md` so the agent uses the right one.