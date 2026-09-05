# GraphQL Star Wars Server (Basic) — Flogo 3

## Overview

This sample demonstrates how to build a **GraphQL server** in the **TIBCO Flogo® 3** folder-based project format using the **GraphQL Trigger** with an app-level GraphQL spec. A single GraphQL endpoint serves the classic Star Wars schema, with one resolver flow per query and mutation defined in the schema.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **GraphQL Trigger** | `github.com/project-flogo/graphql/trigger/graphql` | Exposes a GraphQL endpoint on `/graphql` (port `7879`); each query/mutation is routed to a resolver flow |
| **App-level spec** | `spec://StarWarsSchema.gql` | The GraphQL schema is imported once at the app level and referenced by the trigger |
| **Log** | `github.com/tibco/flogo-general/.../activity/log` | Logs the incoming arguments for each resolver |
| **Return** | `github.com/project-flogo/contrib/activity/actreturn` | Returns the resolved GraphQL response payload |

> Flogo supports the `Query` and `Mutation` operation types. The `Subscription` type is not supported.

## Architecture

```
  GraphQL client (curl / Postman / GraphQL IDE)
      |
      |  POST http://localhost:7879/graphql
      v
 +--------------------------------------------------------------+
 |  GraphqlStarWars  (Flogo 3 app)                            |
 |                                                              |
 |  GraphQL Trigger (path /graphql, port 7879)                 |
 |    schema = spec://StarWarsSchema.gql, introspection = on   |
 |        |            |            |               |           |
 |   Query hero   Query human   Query droid   Mutation review  |
 |        v            v            v               v           |
 |  Query_hero    Query_human   Query_droid   Mutation_createReview
 |        \____________\____________/______________/           |
 |                     Log -> Return                            |
 +--------------------------------------------------------------+
```

- The schema declares three queries (`hero`, `human`, `droid`) and one mutation (`createReview`). Each maps to a resolver flow selected by the trigger handler's `operation` + `resolverFor` settings.
- Every resolver flow follows the same shape: **Log** the incoming arguments, then **Return** the response. In this basic sample the responses are static example data illustrating the resolved shape.

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `GraphqlStarWars/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name `GraphqlStarWars`, version `1.1.0`) |
| `GraphqlStarWars/app.fgprops` | App properties (none defined for this sample) |
| `GraphqlStarWars/specs/StarWarsSchema.gql` | App-level GraphQL schema referenced by the trigger |
| `GraphqlStarWars/triggers/GraphQLTrigger.fgtrigger` | GraphQL trigger — `/graphql` on port `7879`, introspection enabled |
| `GraphqlStarWars/flows/Query_hero.fgflow` | Resolver for `Query.hero` (argument `episode`) |
| `GraphqlStarWars/flows/Query_human.fgflow` | Resolver for `Query.human` (argument `id`) |
| `GraphqlStarWars/flows/Query_droid.fgflow` | Resolver for `Query.droid` (argument `id`) |
| `GraphqlStarWars/flows/Mutation_createReview.fgflow` | Resolver for `Mutation.createReview` (argument `characterReview`) |

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed.
- A GraphQL client for testing (curl, Postman, or any GraphQL IDE).

## Setup & Run

### Step 1 — Open the app in VS Code

Open this `Basic` sample folder in Visual Studio Code with the Flogo 3 extension. The extension detects the `GraphqlStarWars` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

This sample defines no app properties, so no configuration is required. If you want to change the listen port or path, edit the `port`/`path` settings in `triggers/GraphQLTrigger.fgtrigger`.

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save. (The GraphQL connector is pure Go, so no special build environment is needed.)

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The GraphQL server starts listening on port **7879** at path `/graphql`.

### Step 5 — Invoke the endpoint

Query the `hero` resolver:

```bash
curl -X POST http://localhost:7879/graphql \
  -H "Content-Type: application/json" \
  -d '{"query":"{ hero(episode: EMPIRE) { id name appearsIn ... on Human { homePlanet } } }"}'
```

You should receive the character payload returned by the `Query_hero` flow (e.g. `Luke`), and the Log activity prints the incoming argument to the terminal.

Query the `human` resolver:

```bash
curl -X POST http://localhost:7879/graphql \
  -H "Content-Type: application/json" \
  -d '{"query":"{ human(id: \"h123\") { id name homePlanet } }"}'
```

Run the `createReview` mutation:

```bash
curl -X POST http://localhost:7879/graphql \
  -H "Content-Type: application/json" \
  -d '{"query":"mutation { createReview(characterReview: {id: \"h123\", rating: 5, comment: \"Great\"}) { reviewId rating comment } }"}'
```

Because introspection is enabled, you can also query the schema itself (for example with the `__schema` meta-field) from any GraphQL IDE.

## App Properties Reference

This sample does not define any app properties.

| Property | Default | Description |
|---|---|---|
| *(none)* | — | No app-level properties are used by this sample |

Trigger settings of interest (in `GraphQLTrigger.fgtrigger`):

| Setting | Value | Description |
|---|---|---|
| `port` | `7879` | Port the GraphQL server listens on |
| `path` | `/graphql` | HTTP path for the GraphQL endpoint |
| `introspection` | `true` | Allow schema introspection queries |
| `secureConnection` | `false` | TLS disabled (plain HTTP) |
| `schemaFile` | `spec://StarWarsSchema.gql` | App-level schema reference |

## Troubleshooting

- **`address already in use` on startup** — port `7879` is taken. Change the `port` in `triggers/GraphQLTrigger.fgtrigger` (and update your client URL).
- **`404` or empty response** — verify you are POSTing to `/graphql` on the correct port and sending a JSON body with a `query` field.
- **`Cannot query field ...` / validation errors** — the query does not match `StarWarsSchema.gql`. Only the `hero`, `human`, `droid` queries and the `createReview` mutation are defined. Subscriptions are not supported.
- **Resolver returns no data** — confirm the flow's trigger handler `operation`/`resolverFor` matches the schema field name.

## Help

For additional information, visit the [TIBCO Flogo® Connector for GraphQL documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/graphql/overview.htm).
