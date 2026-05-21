# Transform XML Activity

Part of the [XML Extension](../../../../../../README.md). See that file for full usage guidance, mapper examples, and the sample app.

## Inputs

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| XSLT | bytes | Yes | The XSLT 2.0 stylesheet to apply |
| XML | bytes | Yes | The XML document to transform |
| Params | object | No | Runtime XSLT parameter values. Absent or `null` values fall back to the stylesheet's `select=` defaults. |

## Output

| Field | Type | Description |
|-------|------|-------------|
| TransformedXML | bytes | The transformed result |

## Module

```
github.com/davewins/flogo-enterprise-hub/extensions/XML/src/XSLT-Transformer/activity/TransformXML
```
