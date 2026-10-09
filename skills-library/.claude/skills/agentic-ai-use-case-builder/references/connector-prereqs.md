# Connector prerequisites (designtime) — detect and tell the user

Some Flogo connectors need a **prerequisite** (a native driver / client library) installed into
the VS Code Flogo extension for **design-time metadata fetching** — the designer uses it to read
schemas, tables and columns for the connector's activities and to validate the connection. The
app still builds and runs without it. Both agentic skills (FDA and clone) run this check at the
end of every build and list the result in the hand-off.

## Which connectors need a prerequisite

| Connector | Import root to grep for in the `.flogo` |
|---|---|
| PostgreSQL (also used for Amazon Redshift) | `github.com/tibco/wi-postgres` |
| MySQL | `github.com/tibco/wi-mysql` |
| Microsoft SQL Server | `github.com/tibco/wi-mssql` |
| Oracle Database | `github.com/tibco/wi-oracledb` |
| IBM MQ | `github.com/tibco/wi-ibmmq` |
| TIBCO EMS | `github.com/tibco/flogo-ems` |
| TIBCO FTL | `github.com/tibco/flogo-ftl-connector` |
| TIBCO ActiveSpaces | `github.com/tibco/flogo-activespaces` |
| gRPC | `github.com/project-flogo/grpc` |

The agentic use cases always use **PostgreSQL** (MCP server + A2A agents), so at least that one
always applies.

## Detect (read-only)

```bash
for c in tibco/wi-postgres tibco/wi-mysql tibco/wi-mssql tibco/wi-oracledb tibco/wi-ibmmq \
         tibco/flogo-ems tibco/flogo-ftl-connector tibco/flogo-activespaces project-flogo/grpc; do
  hits=$(grep -l "github.com/$c/" <UseCaseDir>/*.flogo 2>/dev/null | tr '\n' ' ')
  [ -n "$hits" ] && echo "$c -> $hits"
done
```

`grep` only reads the files — never "fix" a missing prerequisite by editing the `.flogo`.

## What to tell the user (paste into the hand-off and the README)

> **Install the connector prerequisites before opening these apps in the designer.** They are
> required for design-time metadata fetching (schemas, tables and columns for the activities, and
> connection validation).
> This use case uses: **<PostgreSQL, …>**.
> In VS Code, open the **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for
> Flogo Connectors…**, select the connectors listed above, finish the install, then **reload
> VS Code**. The picker only shows prerequisites that apply to your OS.

If the designer can't list schemas/tables for a connector's activity, or its connection won't
validate, check that the prerequisite is installed (and VS Code reloaded) first.
