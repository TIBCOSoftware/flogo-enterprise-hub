# XML Filter Activity

![XML Filter Activity](https://github.com/mpandav-tibco/flogo-custom-extensions/blob/main/activity/xmlfilter/icons/xmlfilter%402x.png)

This Flogo activity filters XML content based on multiple XPath expressions with configurable AND/OR logic. It evaluates XPath conditions against XML input and returns the original XML string only if the conditions are satisfied according to the specified logic.

## Configuration

### Settings

This activity uses no global settings - all configuration is provided through inputs for maximum flexibility.

### Inputs

| Input | Type | Required | Description | Default |
|-------|------|----------|-------------|---------|
| xmlString | string | Yes | XML string to filter and evaluate | - |
| xpathConditions | array | Yes | Array of XPath condition objects with 'expression' property | - |
| conditionLogic | string | No | Logic to combine multiple conditions: 'AND' or 'OR' | "AND" |

#### XPath Conditions Format

The `xpathConditions` input expects an array of objects with the following structure:

```json
[
  {
    "expression": "/root/element[@id='value']"
  },
  {
    "expression": "//item[text()='specific-text']"
  }
]
```

### Outputs

| Output | Type | Description |
|--------|------|-------------|
| match | boolean | True if conditions match according to logic, false otherwise |
| filteredXmlString | string | Original XML string if conditions match, empty string otherwise |

## Usage Examples

### Example 1: Single Condition Filter

```json
{
  "id": "xml_filter_single",
  "name": "Filter XML by Single Condition",
  "activity": {
    "ref": "github.com/milindpandav/activity/xmlfilter",
    "input": {
      "xmlString": "=$.xmlData",
      "xpathConditions": [
        {
          "expression": "/catalog/book[@id='bk101']"
        }
      ],
      "conditionLogic": "AND"
    },
    "output": {
      "isMatch": "=$.match", 
      "filteredXml": "=$.filteredXmlString"
    }
  }
}
```

### Example 2: Multiple Conditions with AND Logic

```json
{
  "id": "xml_filter_and",
  "name": "Filter XML with AND Logic",
  "activity": {
    "ref": "github.com/milindpandav/activity/xmlfilter",
    "input": {
      "xmlString": "=$.xmlData",
      "xpathConditions": [
        {
          "expression": "/catalog/book[@id='bk101']"
        },
        {
          "expression": "/catalog/book/price[. < 50]"
        },
        {
          "expression": "/catalog/book/genre[text()='Computer']"
        }
      ],
      "conditionLogic": "AND"
    },
    "output": {
      "isMatch": "=$.match",
      "filteredXml": "=$.filteredXmlString"
    }
  }
}
```

### Example 3: Multiple Conditions with OR Logic

```json
{
  "id": "xml_filter_or",
  "name": "Filter XML with OR Logic", 
  "activity": {
    "ref": "github.com/milindpandav/activity/xmlfilter",
    "input": {
      "xmlString": "=$.xmlData",
      "xpathConditions": [
        {
          "expression": "/catalog/book/genre[text()='Fantasy']"
        },
        {
          "expression": "/catalog/book/genre[text()='Romance']"
        },
        {
          "expression": "/catalog/book/genre[text()='Horror']"
        }
      ],
      "conditionLogic": "OR"
    },
    "output": {
      "isMatch": "=$.match",
      "filteredXml": "=$.filteredXmlString"
    }
  }
}
```

### Example 4: Complex XPath Expressions

```json
{
  "id": "xml_filter_complex",
  "name": "Filter XML with Complex XPath",
  "activity": {
    "ref": "github.com/milindpandav/activity/xmlfilter",
    "input": {
      "xmlString": "=$.xmlData",
      "xpathConditions": [
        {
          "expression": "//book[author='Gambardella, Matthew' and price < 50]"
        },
        {
          "expression": "//book[contains(description, 'XML') and publish_date > '2000-01-01']"
        }
      ],
      "conditionLogic": "OR"
    },
    "output": {
      "isMatch": "=$.match",
      "filteredXml": "=$.filteredXmlString"
    }
  }
}
```

## Sample XML Data

Here's a sample XML structure that works with the examples above:

```xml
<?xml version="1.0"?>
<catalog>
   <book id="bk101">
      <author>Gambardella, Matthew</author>
      <title>XML Developer's Guide</title>
      <genre>Computer</genre>
      <price>44.95</price>
      <publish_date>2000-10-01</publish_date>
      <description>An in-depth look at creating applications with XML.</description>
   </book>
   <book id="bk102">
      <author>Ralls, Kim</author>
      <title>Midnight Rain</title>
      <genre>Fantasy</genre>
      <price>5.95</price>
      <publish_date>2000-12-16</publish_date>
      <description>A former architect battles corporate zombies.</description>
   </book>
   <book id="bk103">
      <author>Corets, Eva</author>
      <title>Maeve Ascendant</title>
      <genre>Fantasy</genre>
      <price>5.95</price>
      <publish_date>2000-11-17</publish_date>
      <description>After the collapse of a nanotechnology society.</description>
   </book>
</catalog>
```

## Supported XPath Features

The activity uses the `xmlquery` library which supports XPath 1.0 expressions including:

### Basic Path Expressions
- **Absolute paths**: `/catalog/book`
- **Relative paths**: `book/author`
- **Descendant paths**: `//book`
- **Parent paths**: `../author`

### Predicates and Filters
- **Attribute filters**: `/book[@id='bk101']`
- **Text content**: `/book[title='XML Guide']`
- **Position filters**: `/book[1]`, `/book[last()]`
- **Numeric comparisons**: `/book[price < 50]`

### Functions
- **Text functions**: `text()`, `contains()`
- **Position functions**: `position()`, `last()`
- **Node functions**: `count()`, `name()`
- **String functions**: `substring()`, `string-length()`

### Advanced Features
- **Multiple predicates**: `/book[@id='bk101' and price < 50]`
- **Union operations**: `/book | /magazine`
- **Axes**: `ancestor::`, `descendant::`, `following::`

## Logic Evaluation

### AND Logic
When `conditionLogic` is set to "AND":
- **All conditions must be true** for the overall match to be true
- **Short-circuit evaluation**: Stops at first false condition
- **Empty conditions**: Treated as configuration error
- **Invalid XPath**: Treated as false condition

### OR Logic  
When `conditionLogic` is set to "OR":
- **Any condition being true** makes the overall match true
- **Short-circuit evaluation**: Stops at first true condition
- **Empty conditions**: Treated as configuration error
- **Invalid XPath**: Treated as false condition

## Error Handling

The activity provides comprehensive error handling with specific error codes:

### Input Validation Errors
- **XMLFILTER-4001**: XMLString input not provided or not a string
- **XMLFILTER-4003**: XPathConditions input not provided or not an array
- **XMLFILTER-4004**: XPathConditions element is not a valid object structure
- **XMLFILTER-4005**: XPathConditions element missing 'expression' property
- **XMLFILTER-4006**: XPathConditions array is empty

### Processing Errors
- **XMLFILTER-5001**: XML parsing failed (malformed XML) - Returns error but sets done=true with outputs set to false/empty

### XPath Evaluation
- **Invalid XPath expressions**: Logged as warnings, treated as non-matching conditions
- **XPath evaluation errors**: Logged but don't stop processing of other conditions


## Testing

Run the activity tests:

```bash
# Run all tests
go test -v

# Run with coverage
go test -v -cover

# Run specific test patterns
go test -v -run TestXMLFilter
```

## Dependencies

- `github.com/project-flogo/core` v1.6.12+ - Flogo core framework
- `github.com/antchfx/xmlquery` v1.4.4+ - XPath query library for XML processing
- `github.com/stretchr/testify` v1.8.1+ - Testing framework (test dependency only)


## Integration Usecases

### 🔍 **Content Routing**
Filter XML messages and route only matching content:

```json
{
  "conditionLogic": "AND",
  "xpathConditions": [
    {
      "expression": "/message[@type='order']"
    },
    {
      "expression": "/message/priority[text()='high']"
    }
  ]
}
```

### 📊 **Data Validation**
Validate XML structure before processing:

```json
{
  "conditionLogic": "AND", 
  "xpathConditions": [
    {
      "expression": "/document/header"
    },
    {
      "expression": "/document/body"
    },
    {
      "expression": "/document/@version"
    }
  ]
}
```

### 🛠️ **Multi-Criteria Filtering**
Filter based on multiple business rules:

```json
{
  "conditionLogic": "OR",
  "xpathConditions": [
    {
      "expression": "//product[category='electronics' and price < 1000]"
    },
    {
      "expression": "//product[category='books' and rating > 4]"
    },
    {
      "expression": "//product[@featured='true']"
    }
  ]
}
```

## Best Practices

### 📋 **XPath Expression Guidelines**
1. **Use specific paths**: Prefer `/catalog/book` over `//book` when structure is known
2. **Optimize predicates**: Place most selective conditions first
3. **Avoid deep recursion**: Limit use of `//` for better performance
4. **Test expressions**: Validate XPath syntax before deployment

### 🔧 **Condition Logic**
1. **AND for validation**: Use AND logic when all criteria must be met
2. **OR for alternatives**: Use OR logic for multiple acceptable patterns
3. **Order conditions**: Place most likely to fail conditions first for AND logic
4. **Order conditions**: Place most likely to succeed conditions first for OR logic

## Notes

- The activity preserves the original XML string exactly when conditions match
- XPath expressions are evaluated in the order specified in the array
- Short-circuit evaluation improves performance for multiple conditions
- Invalid XPath expressions are logged but don't prevent other conditions from being evaluated
- Empty condition arrays are treated as configuration errors
- The activity is thread-safe and can be used in concurrent flows
- XML namespaces may be supported through standard XPath namespace syntax (depends on xmlquery library capabilities)
- Large XML documents are handled by the xmlquery library
