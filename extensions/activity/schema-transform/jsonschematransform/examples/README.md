# JSON Schema Transformer Examples

This directory contains comprehensive examples demonstrating the usage of the JSON Schema Transformer activity. Each example showcases different features and use cases for transforming JSON Schemas to XSD and Avro formats.

## Example Files

### 1. User Profile Schema (`user_profile_schema.json`)
A comprehensive user profile schema demonstrating:
- **Complex nested objects** (personalInfo, accountSettings, preferences)
- **String patterns and formats** (UUID, email, phone, date formats)
- **Enums** (country codes, account types)
- **Arrays with constraints** (tags with uniqueItems and maxItems)
- **Boolean defaults and validation**
- **Required field handling**

**Key Features Demonstrated:**
- Format validation (email, date, uuid, date-time)
- Pattern matching for usernames and phone numbers
- Nested object structures with required fields
- Enum constraints for controlled vocabularies
- Array handling with uniqueness constraints

### 2. E-commerce Product Schema (`ecommerce_product_schema.json`)
A complex e-commerce product catalog schema featuring:
- **Union types with oneOf** (size can be enum or pattern-based)
- **AnyOf constraints** for flexible specifications
- **Nested variants** with dynamic attributes
- **Multiple pricing models** with discounts
- **Inventory management** with supplier information
- **Media attachments** with metadata

**Key Features Demonstrated:**
- OneOf unions for flexible field types
- AnyOf for additional specifications
- Complex array structures with nested objects
- Multiple numeric constraints (minimum, multipleOf)
- URI format validation for media URLs
- Dynamic additional properties handling

### 3. REST API Response Schema (`api_response_schema.json`)
A standard API response schema showcasing:
- **Conditional validation with allOf/if-then**
- **OneOf for different response types** (paginated, single object, array)
- **Complex pagination object**
- **Error handling structures**
- **Rate limiting metadata**
- **HATEOS links**

**Key Features Demonstrated:**
- Conditional schema validation based on status
- OneOf unions for different data payload types
- Complex nested pagination structures
- Error and warning arrays with structured objects
- Metadata handling for API governance
- URI format validation for hypermedia links

### 4. Sample Flogo Flow (`sample_flow.json`)
A complete Flogo application demonstrating:
- **HTTP trigger integration**
- **Error handling flow**
- **Dynamic parameter passing**
- **Response formatting**
- **Logging and monitoring**

**Flow Features:**
- REST endpoint at `/transform/json-schema`
- Query parameter support for transformation options
- Conditional error handling with proper HTTP status codes
- Structured JSON responses
- Comprehensive logging at each step

## Usage Examples

### Basic Transformation
```bash
curl -X POST http://localhost:8080/transform/json-schema \
  -H "Content-Type: application/json" \
  -d @user_profile_schema.json
```

### XSD Only Output
```bash
curl -X POST "http://localhost:8080/transform/json-schema?format=xsd&rootElement=UserProfile&namespace=http://example.com/user" \
  -H "Content-Type: application/json" \
  -d @user_profile_schema.json
```

### Avro Only Output
```bash
curl -X POST "http://localhost:8080/transform/json-schema?format=avro&avroRecord=UserProfile&avroNamespace=com.example.user" \
  -H "Content-Type: application/json" \
  -d @user_profile_schema.json
```

### Both Formats
```bash
curl -X POST "http://localhost:8080/transform/json-schema?format=both&rootElement=Product&namespace=http://example.com/product&avroRecord=Product&avroNamespace=com.example.product" \
  -H "Content-Type: application/json" \
  -d @ecommerce_product_schema.json
```

## Expected Outputs

### XSD Output Features
- Root element definition with proper namespacing
- Complex type definitions for nested objects
- Enumeration restrictions for enum fields
- Pattern restrictions for regex validations
- Min/max length constraints for strings
- Numeric bounds and decimal precision
- Choice elements for oneOf/anyOf unions

### Avro Output Features
- Record definitions with proper namespacing
- Union types for optional and variant fields
- Enum definitions for controlled vocabularies
- Array and map types for collections
- Logical types for dates and timestamps
- Default value specifications
- Documentation strings for field descriptions

## Integration Patterns

### Schema Registry Integration
The transformed Avro schemas can be directly registered with Confluent Schema Registry or Azure Schema Registry for Kafka-based data streaming.

### API Gateway Integration
The XSD outputs can be used for SOAP service validation or XML-based API gateway configurations.

### Data Pipeline Integration
Both formats support modern data pipeline architectures:
- **XSD**: For XML-based ETL processes and legacy system integration
- **Avro**: For Kafka streams, Apache Spark, and Hadoop ecosystem integration

## Advanced Features Demonstrated

1. **Union Type Handling**: OneOf, AnyOf, and AllOf constructs
2. **Conditional Validation**: If-then-else logic for dynamic schemas
3. **Format Validation**: Email, URI, date, date-time, UUID formats
4. **Pattern Matching**: Regular expressions for string validation
5. **Numeric Constraints**: Min, max, multipleOf for precise validation
6. **Array Constraints**: UniqueItems, min/maxItems for collection control
7. **Nested Complexity**: Deep object hierarchies with mixed types
8. **Additional Properties**: Dynamic schema extension handling

## Testing the Examples

To test these examples with the JSON Schema Transformer activity:

1. Deploy the sample Flogo flow to your Flogo runtime
2. Use the provided curl commands to test different transformation scenarios
3. Examine the generated XSD and Avro outputs
4. Validate the outputs against your target systems (XML parsers, Avro consumers)

Each example is designed to showcase real-world scenarios and can be adapted for your specific use cases.
