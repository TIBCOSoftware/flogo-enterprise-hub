# Integration Pattern RTK-01 — REST event intake → Kafka

*Stand-in for the integration team's PDF guideline. This is the document the AI agent reads before it builds the golden app.*

## When to use
An operational system (OCC, DCS, baggage handling, MRO, …) pushes a state change over HTTP. The integration layer validates it against the published API contract, turns it into the **canonical enterprise event**, and publishes it to Kafka for any number of consumers.

## Building blocks (fixed names, so every app looks the same)

| # | Activity | Type | Rule |
|---|---|---|---|
| 1 | REST trigger | `tr_rest` from the OpenAPI spec | Spec-first: one operation per app, `operationId` is mandatory. Port comes from app property `HTTP.Port` |
| 2 | `Log_API` | log | Logs every call |
| 3 | `BuildEvent` | mapper | Builds the canonical event; schema named `<Entity>Event` |
| 4 | `PublishEvent` | Kafka producer on connection `EventBus` | Topic from `Event.Topic`, message key = the event's business key, value = the event as JSON |
| 5 | `ConfigureHTTPResponse` → `Return` | HTTP response | The spec's 2xx reply (normally **202 Accepted**) with `eventId`, `status`, `topic` and the business key |

## Canonical event envelope (mandatory fields)
`eventId` (UUID) · `eventType` (fixed, PascalCase past tense, e.g. `FlightStatusChanged`) · `eventTime` · `schemaVersion` · a business key (e.g. `flightKey`, `bagKey`) that is also the Kafka message key. Business fields are grouped by meaning (`flight.*`, `route.*`, `status.*`, `bag.*`, `scan.*`). Codes are upper-cased (IATA carrier, airport, status).

## Configuration: no hard-coded endpoints
| App property | Example | Note |
|---|---|---|
| `HTTP.Port` | `8081` | |
| `Kafka.EventBus.Brokers` | `localhost:9092` | Override per environment at deploy time |
| `Event.Topic` | `ops.flight.status.v1` | `<domain>.<entity>.<event>.v<major>`, lower case |

## Mapping specification
Analysts write the mapping in an Excel workbook with two sheets: **Event** (how the event is built from the request) and **Response** (what the API replies). Columns: *Target Field · Type · Mapping Rule · Description*.

| Notation | Meaning |
|---|---|
| `request.flightNumber` | a field of the REST request body |
| `event.eventId` | a field of the built event (Response sheet) |
| `[Event.Topic]` | an app property |
| `"ACCEPTED"` | a fixed value |
| `UPPER()` `LOWER()` `TRIM()` `concat()` `newUUID()` `now()` `asString()` `asInt()` `asNumber()` | functions |
| `=<Flogo expression>` | escape hatch for anything else |

Nested targets use dots (`route.origin`). Every `request.*` field must exist in the API spec, and every Response target must exist in the spec's 2xx reply.
