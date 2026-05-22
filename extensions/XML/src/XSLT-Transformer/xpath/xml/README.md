# xml.xpath Function

Part of the [XML Extension](../../../../README.md). See that file for full usage guidance, mapper examples, and the sample app.

## Signature

```
xml.xpath(xpath string, xml string, asXML boolean) string
```

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `xpath` | string | The XPath 2.0 expression to evaluate |
| `xml` | string | The XML document to query |
| `asXML` | boolean | `true` to return results as XML markup; `false` to return plain text content |

## Deploying to TIBCO Platform

Package this function as a zip file with `xml/` as the root entry, then upload it to the **Custom Extensions** section of the TIBCO Flogo capability page before importing any sample apps that use it.

```bash
cd extensions/XML/src/XSLT-Transformer/xpath
zip -r ../../XPATH.zip xml/
```

See the [XML Extension README](../../../../README.md) for the full deployment walkthrough.

## Module

```
github.com/davewins/flogo-enterprise-hub/extensions/XML/src/XSLT-Transformer/xpath/xml
```
