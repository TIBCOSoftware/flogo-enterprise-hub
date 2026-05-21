# XML Extension for TIBCO Flogo®

Provides XML transformation capability using XSLT 2.0 stylesheets and XPath 2.0 expressions, powered by the [`github.com/davewins/xslt`](https://github.com/davewins/xslt) library.

## Activities

| Activity | Description |
|----------|-------------|
| [Transform XML](#transform-xml) | Transforms an XML document using an XSLT 2.0 stylesheet, with optional runtime parameters |

## Functions

| Function | Description |
|----------|-------------|
| [xml.xpath](#xpath-function) | Evaluates an XPath 2.0 expression against an XML string and returns the matching values |

---

## Transform XML

Applies an XSLT 2.0 stylesheet to an XML document and returns the transformed result.

### Inputs

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| XSLT | bytes | Yes | The XSLT 2.0 stylesheet to apply |
| XML | bytes | Yes | The XML document to transform |
| Params | object | No | Key/value map of XSLT parameter values to pass at runtime. Parameters absent from the map use the stylesheet's `select=` defaults. |

### Output

| Field | Type | Description |
|-------|------|-------------|
| TransformedXML | bytes | The result of the transformation |

---

## xpath Function

Evaluates an XPath 2.0 expression against an XML document string and returns the matching content.

### Signature

```
xml.xpath(xpath string, xml string, asXML boolean) string
```

### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `xpath` | string | The XPath 2.0 expression to evaluate |
| `xml` | string | The XML document to query |
| `asXML` | boolean | `true` to return results as XML markup; `false` to return plain text content |

### Return value

| Condition | `asXML = true` | `asXML = false` |
|-----------|---------------|-----------------|
| No match | `""` (empty string) | `""` (empty string) |
| Single match | The matched node serialised as XML | The XPath string-value of the node (all descendant text concatenated) |
| Multiple matches | `<results>` wrapping all matched nodes | Each node's string-value joined by `\n` |
| Atomic result (e.g. `count()`, `string()`) | The value as a string | The value as a string |

### Usage notes

**Use `asXML=true` for element nodes.** When querying element nodes that contain child elements, `asXML=false` returns all descendant text concatenated with no separator, which is rarely useful. Target leaf nodes explicitly if you need plain text:

```
# asXML=false is fine for leaf nodes
xml.xpath("//product[category='Electronics']/name", $flow.xml, boolean.false())
# → Widget A\nGadget B

# asXML=true for whole elements
xml.xpath("//product[category='Electronics']", $flow.xml, boolean.true())
# → <results><product>...</product><product>...</product></results>
```

**Building dynamic XPath expressions.** Use `string.concat` to inject runtime values. The injected value must be wrapped in single quotes inside the XPath predicate:

```
xml.xpath(string.concat("//product[category='", $flow.queryParams.category, "']"), $flow.xml, boolean.true())
```

Do not place the value outside the predicate brackets — `string.concat("//product[category]=", $flow.queryParams.category)` produces a boolean comparison, not a node selection, and will return `"false"`.

### Examples

Given this XML:

```xml
<?xml version='1.0'?>
<catalog>
  <product><name>Widget A</name><category>Electronics</category><price>29.99</price></product>
  <product><name>Gadget B</name><category>Electronics</category><price>99.99</price></product>
  <product><name>Gizmo C</name><category>Tools</category><price>15.00</price></product>
</catalog>
```

| Expression | `asXML` | Result |
|------------|---------|--------|
| `//product[category='Electronics']` | `true` | `<results><product>...</product><product>...</product></results>` |
| `//product[category='Electronics']/name` | `false` | `Widget A\nGadget B` |
| `//product[category='Electronics']/price` | `false` | `29.99\n99.99` |
| `count(//product)` | `false` | `3` |
| `//product[category='Tools']` | `true` | `<product><name>Gizmo C</name>...</product>` |

---

## Usage in the Flogo Mapper

### Providing XSLT and XML

Both inputs are `bytes`. Use `coerce.toBytes()` to convert a string literal:

```
coerce.toBytes("<?xml version='1.0'?><catalog>...</catalog>")
```

Pass the output of a previous activity or flow variable in the same way:

```
coerce.toBytes($flow.xmlPayload)
```

### Providing Parameters

The simplest approach when parameters come from HTTP query params is to pass the trigger's query params object directly:

```
$trigger.queryParams
```

or, if promoted to a flow variable:

```
$flow.queryParams
```

The activity automatically ignores any `null`/`nil` values in the map, so parameters defined in the trigger schema but absent from the request will fall back to the stylesheet's defaults.

To pass a hand-built object, use a JSON literal in the mapper expression:

```
{"category": $flow.queryParams.category, "maxPrice": $flow.queryParams.maxPrice}
```

### Reading the output

`TransformedXML` is `bytes`. Convert to a string for logging or returning in a REST response:

```
coerce.toString($activity[TransformXML].TransformedXML)
```

---

## Writing XSLT for the Flogo Mapper

When embedding XSLT inside a `coerce.toBytes("...")` mapper expression, observe these quoting rules:

**1. Use single quotes for XML attributes and double quotes for XPath string literals.**

The outer `coerce.toBytes("...")` uses double quotes, so XML attributes inside must use single quotes:

```
coerce.toBytes("... <xsl:param name='category' select='\"All\"'/> ...")
```

**2. Use the `select` attribute for parameter defaults, not text content.**

The text-content form (`<xsl:param name='x'>val</xsl:param>`) produces a document node rather than a plain string and causes string comparisons to fail in some processors. Use `select` instead:

```xml
<!-- correct -->
<xsl:param name='category' select='"All"'/>
<xsl:param name='maxPrice' select='9999'/>

<!-- avoid -->
<xsl:param name='category'>All</xsl:param>
```

**3. Escape double quotes inside `coerce.toBytes("...")` with `\"`.**

When the XSLT contains XPath string literals (double-quoted) inside a double-quoted `coerce.toBytes` call, escape them:

```
coerce.toBytes("... $category = \"All\" ...")
```

**4. Use `&lt;` for `<` inside XPath predicates.**

XPath comparison operators inside XML attributes must be XML-escaped:

```xml
<xsl:for-each select='items/item[number(price) &lt;= number($maxPrice)]'>
```

---

## Sample Application

A working sample Flogo app is provided in [`samples/XSLT-Transform.flogo`](samples/XSLT-Transform.flogo).

It demonstrates two flows:

- **TransformationFlow** — a startup flow that applies a static XSLT to a hardcoded XML catalog and logs the result.
- **Parameterised** — a REST flow (`GET /product`) that accepts optional `category` (string) and `maxPrice` (number) query parameters and filters a product catalog accordingly.

### Sample requests

```bash
# All products (no filter)
curl "http://localhost:9999/product"

# Electronics only
curl "http://localhost:9999/product?category=Electronics"

# All products under $30
curl "http://localhost:9999/product?maxPrice=30"

# Electronics under $50
curl "http://localhost:9999/product?category=Electronics&maxPrice=50"
```

---

## Extension Reference

**Transform XML activity**
```
github.com/davewins/flogo-enterprise-hub/extensions/XML/src/XSLT-Transformer/activity/TransformXML
```

**xpath function**
```
github.com/davewins/flogo-enterprise-hub/extensions/XML/src/XSLT-Transformer/xpath/function
```
