# **TIBCO Flogo® Extensions**

This folder contains custom extensions developed for FLOGO.

----------

## Contents

| Type | Location | Description |
|------|----------|-------------|
| [Activities](activity/) | `activity/`, `ssh/`, `gcp/`, `pongo2/`, `openpgp/` | Reusable flow activities for SSH, GCP, templating, PGP, AWS, logging, schema conversion, and XML filtering |
| [Custom Functions](function/) | `function/` | Expression functions extending Flogo's built-in set |
| [Custom Triggers](trigger/) | `trigger/` | Event-driven triggers for external systems |

----------

## Activities

### Community Activities

- [SSH](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/extensions/ssh/README.md): Execute commands over SSH connection
- [GCP](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/extensions/gcp/README.md): Generates ID Tokens from GCP OIDC API
- [Pongo2](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/extensions/pongo2/docs/README.md): Pongo2 template processor activity for dynamic prompt engineering to expose via MCP Trigger
- [openpgp](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/extensions/openpgp/README.md): Encrypt and decrypt openpgp messages

### Custom Activities

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

## Custom Triggers

Located in [`trigger/`](trigger/):

| Trigger | Description |
|---------|-------------|
| [`postgreslistener`](trigger/postgreslistener/README.md) | Listens for real-time PostgreSQL NOTIFY messages on configured channels using PostgreSQL's native LISTEN/NOTIFY mechanism |

----------

## Version History

| Extension Name | Version | Last Change             |
| -------------- | ------- | ----------------------- |
| ssh            | 1.0.0   | 24th July 2025, New     |
| gcp            | 1.0.0   | 24th July 2025, New     |
| pongo2         | 1.0.0   | 18th December 2025, New |
| openpgp        | 1.0.0   | 18th March 2026, New    |

----------

## Feedback

Please contact us at [integration-pm@tibco.com](mailto:integration-pm@tibco.com) with any queries, feedback or comments.

----------
