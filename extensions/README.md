# **TIBCO Flogo® Extensions**

This folder contains custom extensions developed for FLOGO.

----------

## Contents

| Type | Location | Description |
|------|----------|-------------|
| [Custom Functions](function/) | `function/` | Expression functions extending Flogo's built-in set |
| [Custom Activities](activity/) | `activity/` | Reusable flow activities for AWS, logging, schema conversion, and XML filtering |
| [Custom Triggers](trigger/) | `trigger/` | Event-driven triggers for external systems |

----------

## Custom Functions

Located in [`function/`](function/), these expression functions extend Flogo's built-in library across **7 packages**:

| Package | Description |
|---------|-------------|
| [`math`](function/math/) | Absolute value, power, square root, logarithms, sign, clamp |
| [`array`](function/array/) | Min, max, avg, sort, filter, pluck, unique, sumBy, indexOf, first, last |
| [`string`](function/string/) | Pad, mask, truncate, case conversion, regex extract, format, validators |
| [`util`](function/util/) | Coalesce, SHA-256, HMAC-SHA256, MD5, Base64 URL encode/decode |
| [`datetime`](function/datetime/) | Compare, epoch conversion, business days, weekend/weekday checks, quarter |
| [`number`](function/number/) | Cryptographically random integer in a range |
| [`json`](function/json/) | Remove key, shallow-merge objects |

See [function/README.md](function/README.md) for full function signatures and descriptions.

----------

## Custom Activities

Located in [`activity/`](activity/):

| Activity | Description |
|----------|-------------|
| [`awssignaturev4`](activity/awssignaturev4/README.md) | Generates AWS Signature Version 4 authentication headers for REST API calls to any AWS service |
| [`write-log`](activity/write-log/README.md) | Structured logging with ECS compliance, field filtering, sensitive data masking, and OpenTelemetry integration |
| [`avroschematransform`](activity/schema-transform/avroschematransform/README.md) | Transforms Avro schemas to JSON Schema and/or XSD formats |
| [`jsonschematransform`](activity/schema-transform/jsonschematransform/README.md) | Transforms JSON Schema to XSD and Avro schema formats |
| [`xsdschematransform`](activity/schema-transform/xsdschematransform/README.md) | Transforms XSD schemas to JSON Schema and Avro schema formats |
| [`xmlfilter`](activity/xmlfilter/README.md) | Filters XML content based on multiple XPath expressions with configurable AND/OR logic |

----------

## Custom Triggers

Located in [`trigger/`](trigger/):

| Trigger | Description |
|---------|-------------|
| [`postgreslistener`](trigger/postgreslistener/README.md) | Listens for real-time PostgreSQL NOTIFY messages on configured channels using PostgreSQL's native LISTEN/NOTIFY mechanism |

----------

## Feedback ##

Please contact us at [integration-pm@tibco.com](mailto:integration-pm@tibco.com) with any queries, feedback or comments.

----------

