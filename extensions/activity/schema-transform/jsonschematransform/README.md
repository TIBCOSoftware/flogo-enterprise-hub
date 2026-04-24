# JSON Schema Transformer Activity

A Flogo activity that transforms JSON Schema to XSD and Avro schema formats. This activity provides bidirectional schema conversion capabilities, enabling seamless interoperability between JSON-based systems and XML/Avro-based systems.

## Overview

This activity transforms JSON Schema documents into equivalent XSD (XML Schema Definition) and Avro schema formats, enabling interoperability across different data serialization standards. The activity supports comprehensive JSON Schema features and provides flexible output format selection.

## Features

- **Multi-Format Output**: Convert JSON Schema to XSD, Avro, or both formats simultaneously
- **Comprehensive JSON Schema Support**: Handles all standard JSON Schema types and constraints
- **Advanced Schema Features**: Supports unions (anyOf, oneOf, allOf), conditional schemas, and constraints
- **String Format Support**: Converts JSON Schema format types (date, date-time, email, uri) to appropriate target formats
- **Enumeration Support**: Converts JSON Schema enum constraints to target format equivalents
- **Constraint Mapping**: Preserves validation constraints (pattern, length, numeric bounds) in target formats
- **Flexible Configuration**: Customizable element names, namespaces, and output format selection
- **High Performance**: Optimized for enterprise-scale schema processing
- **Zero External Dependencies**: Uses only Go standard library and Flogo core

## Configuration

### Settings

| Setting | Type | Required | Description | Default |
|---------|------|----------|-------------|---------|
| outputFormat | string | No | Output format: 'xsd', 'avro', or 'both' | both |

### Inputs

| Input | Type | Required | Description | Default |
|-------|------|----------|-------------|---------|
| jsonSchemaString | string | Yes | The JSON Schema to transform | - |
| outputFormat | string | No | Override default output format ('xsd', 'avro', or 'both') | "both" |
| rootElementName | string | No | Root element name for XSD generation | "RootElement" |
| targetNamespace | string | No | Target namespace for XSD generation | "" (no namespace) |
| avroRecordName | string | No | Root record name for Avro generation | "RootRecord" |
| avroNamespace | string | No | Namespace for Avro generation | "com.example" |

**Note**: The activity intelligently processes only the required inputs based on the selected outputFormat. When outputFormat is 'xsd', Avro-related inputs are ignored. When outputFormat is 'avro', XSD-related inputs are ignored.

### Outputs

| Output | Type | Description |
|--------|------|-------------|
| xsdString | string | Generated XSD string (empty if outputFormat is 'avro') |
| avroSchema | string | Generated Avro schema (empty if outputFormat is 'xsd') |
| error | boolean | Indicates if an error occurred |
| errorMessage | string | Error details if transformation failed |

## Supported JSON Schema Features

### Primitive Types
- `string` → XSD: `xs:string` (with format mapping), Avro: `string`
- `integer` → XSD: `xs:integer`, Avro: `long`
- `number` → XSD: `xs:decimal`, Avro: `double`
- `boolean` → XSD: `xs:boolean`, Avro: `boolean`
- `null` → XSD: nillable element, Avro: `null`

### Complex Types
- **Object** → XSD: `complexType` with sequence, Avro: `record` with fields
- **Array** → XSD: element with `maxOccurs="unbounded"`, Avro: `array` with items
- **Enum** → XSD: `xs:string` with enumeration restrictions, Avro: `enum` with symbols

### Schema Composition
- **anyOf** → XSD: `xs:choice`, Avro: union type `[type1, type2, ...]`
- **oneOf** → XSD: `xs:choice`, Avro: union type `[type1, type2, ...]`
- **allOf** → XSD: merged sequence, Avro: merged record fields
- **const** → XSD: single enumeration value, Avro: enum with single symbol

### Constraints and Validation
- **String constraints**: pattern, minLength, maxLength → XSD facets, Avro: metadata
- **Numeric constraints**: minimum, maximum, exclusiveMinimum, exclusiveMaximum → XSD facets
- **Array constraints**: minItems, maxItems → XSD occurrence constraints
- **Format constraints**: date, date-time, email, uri → XSD type mapping

### Advanced Features
- **Required fields**: Controls XSD minOccurs and Avro optional unions
- **Default values**: Preserved in Avro schemas
- **Descriptions**: Mapped to XSD documentation and Avro doc fields
- **Nested objects**: Full support for deep object hierarchies
- **Additional properties**: Mapped to Avro map types

## Sample JSON Schema

```json
{
  "type": "object",
  "description": "User profile information",
  "properties": {
    "id": {
      "type": "string",
      "pattern": "^USER-[0-9]{6}$",
      "description": "Unique user identifier"
    },
    "name": {
      "type": "string",
      "minLength": 1,
      "maxLength": 100
    },
    "email": {
      "type": "string",
      "format": "email"
    },
    "age": {
      "type": "integer",
      "minimum": 0,
      "maximum": 120
    },
    "status": {
      "type": "string",
      "enum": ["active", "inactive", "pending"],
      "default": "pending"
    },
    "tags": {
      "type": "array",
      "items": {"type": "string"},
      "minItems": 0,
      "maxItems": 10
    },
    "profile": {
      "type": "object",
      "properties": {
        "bio": {"type": "string"},
        "website": {"type": "string", "format": "uri"}
      }
    },
    "preferences": {
      "anyOf": [
        {"type": "null"},
        {
          "type": "object",
          "properties": {
            "theme": {"type": "string"},
            "notifications": {"type": "boolean"}
          }
        }
      ]
    }
  },
  "required": ["id", "name", "email", "age"]
}
```

## Generated XSD

```xml
<?xml version="1.0" encoding="UTF-8"?>
<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" 
           xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
           elementFormDefault="qualified" 
           targetNamespace="http://example.com/user">
  <xs:element name="User">
    <xs:complexType>
      <xs:sequence>
        <xs:element name="id">
          <xs:simpleType>
            <xs:restriction base="xs:string">
              <xs:pattern value="^USER-[0-9]{6}$"/>
            </xs:restriction>
          </xs:simpleType>
        </xs:element>
        <xs:element name="name">
          <xs:simpleType>
            <xs:restriction base="xs:string">
              <xs:minLength value="1"/>
              <xs:maxLength value="100"/>
            </xs:restriction>
          </xs:simpleType>
        </xs:element>
        <xs:element name="email">
          <xs:simpleType>
            <xs:restriction base="xs:string">
              <xs:pattern value="^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"/>
            </xs:restriction>
          </xs:simpleType>
        </xs:element>
        <xs:element name="age">
          <xs:simpleType>
            <xs:restriction base="xs:integer">
              <xs:minInclusive value="0"/>
              <xs:maxInclusive value="120"/>
            </xs:restriction>
          </xs:simpleType>
        </xs:element>
        <xs:element name="status" minOccurs="0">
          <xs:simpleType>
            <xs:restriction base="xs:string">
              <xs:enumeration value="active"/>
              <xs:enumeration value="inactive"/>
              <xs:enumeration value="pending"/>
            </xs:restriction>
          </xs:simpleType>
        </xs:element>
        <xs:element name="tags" type="xs:string" minOccurs="0" maxOccurs="10"/>
        <xs:element name="profile" minOccurs="0">
          <xs:complexType>
            <xs:sequence>
              <xs:element name="bio" type="xs:string" minOccurs="0"/>
              <xs:element name="website" type="xs:anyURI" minOccurs="0"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name="preferences" nillable="true" minOccurs="0">
          <xs:complexType>
            <xs:sequence>
              <xs:element name="theme" type="xs:string" minOccurs="0"/>
              <xs:element name="notifications" type="xs:boolean" minOccurs="0"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>
```

## Generated Avro Schema

```json
{
  "type": "record",
  "name": "UserRecord",
  "namespace": "com.example.user",
  "doc": "User profile information",
  "fields": [
    {
      "name": "id",
      "type": "string",
      "doc": "Unique user identifier"
    },
    {
      "name": "name",
      "type": "string"
    },
    {
      "name": "email",
      "type": "string"
    },
    {
      "name": "age",
      "type": "long"
    },
    {
      "name": "status",
      "type": [
        "null",
        {
          "type": "enum",
          "name": "statusEnum",
          "symbols": ["active", "inactive", "pending"]
        }
      ],
      "default": null
    },
    {
      "name": "tags",
      "type": [
        "null",
        {
          "type": "array",
          "items": "string"
        }
      ],
      "default": null
    },
    {
      "name": "profile",
      "type": [
        "null",
        {
          "type": "record",
          "name": "profileRecord",
          "fields": [
            {
              "name": "bio",
              "type": ["null", "string"],
              "default": null
            },
            {
              "name": "website",
              "type": ["null", "string"],
              "default": null
            }
          ]
        }
      ],
      "default": null
    },
    {
      "name": "preferences",
      "type": [
        "null",
        {
          "type": "record",
          "name": "preferencesRecord",
          "fields": [
            {
              "name": "theme",
              "type": ["null", "string"],
              "default": null
            },
            {
              "name": "notifications",
              "type": ["null", "boolean"],
              "default": null
            }
          ]
        }
      ],
      "default": null
    }
  ]
}
```

## Error Handling

The activity provides comprehensive error handling with specific error codes:

- `INVALID_INPUT` - Invalid or missing required input parameters
- `SCHEMA_PARSE_ERROR` - Invalid JSON Schema JSON
- `XSD_CONVERSION_ERROR` - Error during XSD generation
- `AVRO_CONVERSION_ERROR` - Error during Avro schema generation

## Testing

Run the unit tests:

```bash
go test -v
```

Run benchmarks:

```bash
go test -bench=.
```

## Dependencies

- `github.com/project-flogo/core` - Flogo core framework
- `github.com/stretchr/testify` - Testing framework (for tests)

## Notes

- Union types are mapped to XSD choice elements and Avro union types
- Optional fields are handled via XSD minOccurs="0" and Avro null unions
- String format constraints are preserved in both target formats where possible
- Nested objects create appropriate complex types in both XSD and Avro
- The activity maintains semantic equivalence across all target formats

This activity provides the most comprehensive JSON Schema transformation capabilities, supporting the full spectrum of modern schema conversion requirements.
