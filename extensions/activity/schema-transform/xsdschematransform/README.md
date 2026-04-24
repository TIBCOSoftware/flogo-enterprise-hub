# XSD Schema Transform Activity

![XSD Schema Transform Activity](icons/xsd-schema-transform@2x.png)

This Flogo activity provides comprehensive XSD (XML Schema Definition) transformation capabilities, supporting conversion to JSON Schema and Avro Schema formats. It offers extensive configuration options for handling complex XSD features, namespace management, and output optimization.

## Configuration

### Settings

This activity uses no global settings - all configuration is provided through inputs for maximum flexibility.

### Inputs

| Input | Type | Required | Description | Default |
|-------|------|----------|-------------|---------|
| xsdString | string | Yes | XSD schema string to transform | - |
| outputFormat | string | No | Output format: 'jsonschema', 'avro', or 'both' | "both" |
| validateInput | boolean | No | Validate XSD schema before conversion | false |
| preserveOrder | boolean | No | Preserve element order when possible | false |
| optimizeOutput | boolean | No | Optimize output schema structure | false |
| jsonSchemaVersion | string | No | JSON Schema version: 'draft-04', 'draft-07', '2019-09', '2020-12' | "2020-12" |
| jsonSchemaTitle | string | No | JSON Schema title | - |
| jsonSchemaId | string | No | JSON Schema $id | - |
| addExamples | boolean | No | Add example values from XSD | false |
| avroRecordName | string | No | Root record name for Avro schema | "RootRecord" |
| avroNamespace | string | No | Namespace for Avro schema | "com.example" |
| avroLogicalTypes | boolean | No | Enable Avro logical types (date, time, decimal, etc.) | false |
| avroUnionMode | string | No | Avro union handling: 'nullable', 'strict', 'permissive' | "nullable" |
| handleAny | string | No | How to handle xs:any elements: 'object', 'string', 'ignore' | "object" |
| handleChoice | string | No | How to handle xs:choice: 'union', 'oneof', 'anyof' | "union" |
| includeAttributes | boolean | No | Include XML attributes in conversion | true |
| namespaceHandling | string | No | Namespace handling: 'ignore', 'prefix', 'separate' | "ignore" |
| complexTypeMode | string | No | Complex type handling: 'inline', 'definitions', 'refs' | "inline" |

### Outputs

| Output | Type | Description |
|--------|------|-------------|
| jsonSchemaString | string | Generated JSON Schema string (empty if outputFormat is 'avro') |
| avroSchemaString | string | Generated Avro Schema string (empty if outputFormat is 'jsonschema') |
| validationResult | string | XSD validation result as JSON string |
| conversionStats | string | Conversion statistics as JSON string |
| error | boolean | Whether an error occurred during conversion |
| errorMessage | string | Error message if error occurred |

**Note**: The activity intelligently processes only the required inputs based on the selected outputFormat. When outputFormat is 'jsonschema', Avro-related inputs are ignored. When outputFormat is 'avro', JSON Schema-related inputs are ignored.

## Supported Output Formats

### JSON Schema
Generated JSON Schema follows the specified version (draft-04, draft-07, 2019-09, or 2020-12):

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://example.com/user.schema.json",
  "title": "User Schema",
  "type": "object",
  "properties": {
    "id": {"type": "integer"},
    "name": {"type": "string"},
    "email": {"type": "string", "format": "email"},
    "age": {"type": "integer", "minimum": 0},
    "active": {"type": "boolean"},
    "address": {
      "type": "object",
      "properties": {
        "street": {"type": "string"},
        "city": {"type": "string"},
        "zipcode": {"type": "string"}
      },
      "required": ["street", "city"]
    }
  },
  "required": ["id", "name", "email"]
}
```

### Avro Schema
Generated Avro Schema with logical types support:

```json
{
  "type": "record",
  "name": "User",
  "namespace": "com.example.user",
  "fields": [
    {"name": "id", "type": "long"},
    {"name": "name", "type": "string"},
    {"name": "email", "type": "string"},
    {"name": "age", "type": ["null", "int"], "default": null},
    {"name": "active", "type": "boolean", "default": true},
    {"name": "birthDate", "type": ["null", {"type": "int", "logicalType": "date"}], "default": null},
    {"name": "address", "type": {
      "type": "record",
      "name": "Address",
      "fields": [
        {"name": "street", "type": "string"},
        {"name": "city", "type": "string"},
        {"name": "zipcode", "type": ["null", "string"], "default": null}
      ]
    }}
  ]
}
```

## Supported XSD Features

### Simple Types
- **Basic Types**: `xs:string`, `xs:int`, `xs:long`, `xs:boolean`, `xs:decimal`, `xs:double`, `xs:float`
- **Date/Time Types**: `xs:date`, `xs:time`, `xs:dateTime`, `xs:duration`
- **Restrictions**: `xs:enumeration`, `xs:pattern`, `xs:minLength`, `xs:maxLength`, `xs:minInclusive`, `xs:maxInclusive`

### Complex Types
- **Sequence**: `xs:sequence` → JSON object properties, Avro record fields
- **Choice**: `xs:choice` → JSON `anyOf`/`oneOf`, Avro union types
- **All**: `xs:all` → JSON object with all properties optional
- **Attributes**: XML attributes → JSON properties with `@` prefix or separate handling

### Advanced Features
- **Namespaces**: Configurable handling (ignore, prefix, separate)
- **Any Elements**: `xs:any` → configurable as object, string, or ignored
- **Mixed Content**: Handled as string or object based on configuration
- **Extensions**: `xs:extension` and `xs:restriction` support
- **Groups**: `xs:group` definitions and references

## Sample XSD Schema

```xml
<?xml version="1.0" encoding="UTF-8"?>
<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
           targetNamespace="http://example.com/user"
           elementFormDefault="qualified">
           
  <xs:element name="User">
    <xs:complexType>
      <xs:sequence>
        <xs:element name="id" type="xs:long"/>
        <xs:element name="name" type="xs:string"/>
        <xs:element name="email" type="xs:string" minOccurs="0"/>
        <xs:element name="age" type="xs:int"/>
        <xs:element name="active" type="xs:boolean" default="true"/>
        <xs:element name="birthDate" type="xs:date" minOccurs="0"/>
        <xs:element name="tags" type="xs:string" maxOccurs="unbounded"/>
        <xs:element name="address" type="AddressType"/>
      </xs:sequence>
      <xs:attribute name="version" type="xs:string" use="required"/>
    </xs:complexType>
  </xs:element>
  
  <xs:complexType name="AddressType">
    <xs:sequence>
      <xs:element name="street" type="xs:string"/>
      <xs:element name="city" type="xs:string"/>
      <xs:element name="zipcode" type="xs:string" minOccurs="0"/>
    </xs:sequence>
  </xs:complexType>
  
  <xs:simpleType name="StatusType">
    <xs:restriction base="xs:string">
      <xs:enumeration value="active"/>
      <xs:enumeration value="inactive"/>
      <xs:enumeration value="pending"/>
    </xs:restriction>
  </xs:simpleType>
</xs:schema>
```

## Conversion Statistics

The activity provides detailed conversion statistics:

```json
{
  "elementsProcessed": 15,
  "attributesProcessed": 3,
  "complexTypesFound": 2,
  "simpleTypesFound": 8,
  "choicesFound": 1,
  "unionsCreated": 3,
  "constraintsApplied": 5,
  "namespacesFound": ["http://example.com/user"],
  "typeMapping": {
    "xs:string": "string",
    "xs:int": "integer",
    "xs:date": "string"
  },
  "warnings": [
    "Mixed content in element 'description' converted to string"
  ]
}
```

## Error Handling

The activity provides comprehensive error handling with specific error categories:

- **INVALID_INPUT** - Invalid or missing input parameters
- **XSD_PARSE_ERROR** - Error parsing XSD schema structure  
- **XSD_CONVERSION_ERROR** - Error during XSD to universal format conversion
- **JSONSCHEMA_GENERATION_ERROR** - Error generating JSON Schema output
- **AVRO_GENERATION_ERROR** - Error generating Avro Schema output

## Testing

Run the comprehensive test suite:

```bash
# Run all tests
go test -v

# Run specific test methods
go test -v -run TestXSDSchemaTransformActivity
go test -v -run TestXSDSchemaTransformActivity_JSONSchemaOnly
go test -v -run TestXSDSchemaTransformActivity_AvroOnly
go test -v -run TestXSDSchemaTransformActivity_InvalidXSD
go test -v -run TestXSDSchemaTransformActivity_EmptyXSD

# Run with coverage
go test -v -cover
```

## Dependencies

- `github.com/project-flogo/core` v1.6.0+ - Flogo core framework
- `github.com/stretchr/testify` v1.4.0+ - Testing framework


## Best Practices

### 📋 General Guidelines
1. **Validate Input**: Enable `validateInput` for production use
2. **Choose Appropriate Format**: Use 'both' only when you need both outputs
3. **Optimize Output**: Enable `optimizeOutput` for better performance
4. **Handle Namespaces**: Configure namespace handling based on your use case
5. **Use Logical Types**: Enable Avro logical types for better data representation

### 🔧 Configuration Recommendations
1. **Enterprise**: Use `complexTypeMode: "definitions"` for reusable schemas
2. **API Integration**: Use latest JSON Schema version (2020-12)
3. **Data Streaming**: Enable Avro logical types for time-series data
4. **Legacy Systems**: Use `namespaceHandling: "ignore"` for simplicity

### 🎯 Performance Tips
1. Set appropriate output format to avoid unnecessary processing
2. Use `optimizeOutput: true` for large schemas
3. Consider `preserveOrder: false` for better performance
4. Cache converted schemas when possible

## Notes

- All outputs are generated based on the specified `outputFormat`
- Empty outputs are returned for formats not requested
- Conversion statistics provide detailed processing information
- Error handling is comprehensive but non-blocking where possible
- The activity supports the most common XSD features used in enterprise environments
- Complex XSD features like substitution groups have limited support
- Performance scales well with schema complexity
- Compatible with all major schema registries and documentation tools
