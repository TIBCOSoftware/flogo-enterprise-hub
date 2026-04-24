# Avro Schema Transformer Activity

This Flogo activity transforms Avro schemas to JSON Schema and/or XSD formats. It provides flexible conversion capabilities allowing you to generate JSON Schema, XSD, or both formats simultaneously.

## Configuration

### Settings

| Setting | Type | Required | Description | Default |
|---------|------|----------|-------------|---------|
| outputFormat | string | No | Output format: 'json', 'xsd', or 'both' | both |

### Inputs

| Input | Type | Required | Description | Default |
|-------|------|----------|-------------|---------|
| avroSchemaString | string | Yes | The Avro schema JSON string to transform | - |
| outputFormat | string | No | Override default output format ('json', 'xsd', or 'both') | "both" |
| rootElementName | string | No | Root element name for XSD generation | "root" |
| targetNamespace | string | No | Target namespace for XSD generation | "" (no namespace) |

### Outputs

| Output | Type | Description |
|--------|------|-------------|
| jsonSchema | string | Generated JSON Schema (empty if outputFormat is 'xsd') |
| xsdString | string | Generated XSD string (empty if outputFormat is 'json') |
| error | boolean | Indicates if an error occurred |
| errorMessage | string | Error details if transformation failed |

**Note**: The activity intelligently processes only the required inputs based on the selected outputFormat. When outputFormat is 'json', XML-related inputs (rootElementName, targetNamespace) are ignored. When outputFormat is 'xsd' or 'both', these inputs are processed with default values if not provided.


## Supported Avro Types

### Primitive Types
- `null` → JSON: `null`, XSD: `xs:string` (optional)
- `boolean` → JSON: `boolean`, XSD: `xs:boolean`
- `int`/`long` → JSON: `integer`, XSD: `xs:integer`
- `float`/`double` → JSON: `number`, XSD: `xs:decimal`
- `bytes` → JSON: `string`, XSD: `xs:base64Binary`
- `string` → JSON: `string`, XSD: `xs:string`

### Complex Types
- **Record** → JSON: `object` with properties, XSD: `complexType` with sequence
- **Array** → JSON: `array` with items, XSD: element with `maxOccurs="unbounded"`
- **Map** → JSON: `object` with `additionalProperties`, XSD: `xs:anyType`
- **Enum** → JSON: `string` with `enum` constraint, XSD: `xs:string`
- **Fixed** → JSON: `string` with length constraints, XSD: `xs:string`
- **Union** → JSON: `anyOf` or optional field, XSD: `xs:choice` or optional element

## Sample Avro Schema

```json
{
  "type": "record",
  "name": "User",
  "namespace": "com.example",
  "fields": [
    {"name": "id", "type": "long"},
    {"name": "name", "type": "string"},
    {"name": "email", "type": ["null", "string"], "default": null},
    {"name": "age", "type": "int"},
    {"name": "active", "type": "boolean", "default": true},
    {"name": "tags", "type": {"type": "array", "items": "string"}},
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

## Generated JSON Schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "properties": {
    "id": {"type": "integer"},
    "name": {"type": "string"},
    "email": {"type": "string"},
    "age": {"type": "integer"},
    "active": {"type": "boolean"},
    "tags": {
      "type": "array",
      "items": {"type": "string"}
    },
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
  "required": ["id", "name", "age", "active", "tags", "address"]
}
```

## Generated XSD

```xml
<?xml version="1.0" encoding="UTF-8"?>
<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" 
           elementFormDefault="qualified" 
           targetNamespace="http://example.com/user">
  <xs:element name="User">
    <xs:complexType>
      <xs:sequence>
        <xs:element name="id" type="xs:integer"/>
        <xs:element name="name" type="xs:string"/>
        <xs:element name="email" type="xs:string" minOccurs="0"/>
        <xs:element name="age" type="xs:integer"/>
        <xs:element name="active" type="xs:boolean"/>
        <xs:element name="tags" type="xs:string" maxOccurs="unbounded"/>
        <xs:element name="address">
          <xs:complexType>
            <xs:sequence>
              <xs:element name="street" type="xs:string"/>
              <xs:element name="city" type="xs:string"/>
              <xs:element name="zipcode" type="xs:string" minOccurs="0"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>
```

## Error Handling

The activity provides comprehensive error handling with specific error codes:

- `INVALID_INPUT` - Invalid or missing required input parameters
- `SCHEMA_PARSE_ERROR` - Invalid Avro schema JSON
- `JSON_CONVERSION_ERROR` - Error during JSON Schema generation
- `XSD_CONVERSION_ERROR` - Error during XSD generation

## Testing

Run the unit tests:

```bash
go test -v
```

## Dependencies

- `github.com/project-flogo/core` - Flogo core framework
- `github.com/stretchr/testify` - Testing framework (for tests)

## Notes

- Union types with null are treated as optional fields
- Complex union types (more than null + one type) are converted to `anyOf` in JSON Schema and `xs:choice` in XSD
- Map types are simplified to `xs:anyType` in XSD due to XML Schema limitations
- Enum restrictions in XSD would require additional schema definitions not included in basic conversion
