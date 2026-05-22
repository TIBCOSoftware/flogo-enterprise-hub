# Transform XML Activity

Part of the [XML Extension](../../../../README.md). See that file for full usage guidance, mapper examples, and the sample app.

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

## Deploying to TIBCO Platform

Package this activity as a zip file with `TransformXML/` as the root entry, then upload it to the **Custom Extensions** section of the TIBCO Flogo capability page before importing any sample apps that use it.

```bash
cd extensions/XML/src/XSLT-Transformer/activity
zip -r ../../XSLT.zip TransformXML/
```

See the [XML Extension README](../../../../README.md) for the full deployment walkthrough.

## Module

```
github.com/davewins/flogo-enterprise-hub/extensions/XML/src/XSLT-Transformer/activity/TransformXML
```
