#!/bin/bash

# JSON Schema Transformer Examples Test Script
# This script demonstrates how to test the JSON Schema Transformer activity
# with various example schemas and output formats

set -e

# Configuration
FLOGO_ENDPOINT="http://localhost:8080/transform/json-schema"
EXAMPLES_DIR="$(dirname "$0")"
OUTPUT_DIR="${EXAMPLES_DIR}/output"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Create output directory
mkdir -p "$OUTPUT_DIR"

echo -e "${BLUE}=== JSON Schema Transformer Examples Test Suite ===${NC}"
echo ""

# Function to test transformation
test_transformation() {
    local schema_file="$1"
    local format="$2"
    local additional_params="$3"
    local test_name="$4"
    
    echo -e "${YELLOW}Testing: ${test_name}${NC}"
    echo "Schema: $(basename "$schema_file")"
    echo "Format: $format"
    
    local url="${FLOGO_ENDPOINT}?format=${format}${additional_params}"
    local output_file="${OUTPUT_DIR}/$(basename "$schema_file" .json)_${format}_output.json"
    
    if curl -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "@$schema_file" \
        -o "$output_file"; then
        echo -e "${GREEN}✓ Success - Output saved to: $output_file${NC}"
        
        # Pretty print the response
        if command -v jq &> /dev/null; then
            echo "Response preview:"
            jq -r '.xsdString // .avroSchema // .message' "$output_file" | head -5
        fi
    else
        echo -e "${RED}✗ Failed${NC}"
    fi
    echo ""
}

# Check if Flogo endpoint is accessible
echo "Checking Flogo endpoint accessibility..."
if ! curl -s -f "$FLOGO_ENDPOINT" > /dev/null 2>&1; then
    echo -e "${RED}Error: Flogo endpoint $FLOGO_ENDPOINT is not accessible${NC}"
    echo "Please ensure your Flogo application is running with the sample flow deployed."
    exit 1
fi
echo -e "${GREEN}✓ Flogo endpoint is accessible${NC}"
echo ""

# Test 1: User Profile Schema - XSD Output
test_transformation \
    "$EXAMPLES_DIR/user_profile_schema.json" \
    "xsd" \
    "&rootElement=UserProfile&namespace=http://example.com/user" \
    "User Profile to XSD"

# Test 2: User Profile Schema - Avro Output
test_transformation \
    "$EXAMPLES_DIR/user_profile_schema.json" \
    "avro" \
    "&avroRecord=UserProfile&avroNamespace=com.example.user" \
    "User Profile to Avro"

# Test 3: E-commerce Product Schema - Both Formats
test_transformation \
    "$EXAMPLES_DIR/ecommerce_product_schema.json" \
    "both" \
    "&rootElement=Product&namespace=http://example.com/product&avroRecord=Product&avroNamespace=com.example.product" \
    "E-commerce Product to Both Formats"

# Test 4: API Response Schema - XSD Only
test_transformation \
    "$EXAMPLES_DIR/api_response_schema.json" \
    "xsd" \
    "&rootElement=ApiResponse&namespace=http://api.example.com/response" \
    "API Response to XSD"

# Test 5: IoT Sensor Schema - Avro Only
test_transformation \
    "$EXAMPLES_DIR/iot_sensor_schema.json" \
    "avro" \
    "&avroRecord=SensorData&avroNamespace=com.example.iot" \
    "IoT Sensor Data to Avro"

# Test 6: Error handling - Invalid JSON Schema
echo -e "${YELLOW}Testing: Error Handling with Invalid Schema${NC}"
echo '{"invalid": "schema", "missing": "$schema"}' > "$OUTPUT_DIR/invalid_schema.json"
test_transformation \
    "$OUTPUT_DIR/invalid_schema.json" \
    "xsd" \
    "&rootElement=Invalid" \
    "Invalid Schema Error Handling"

# Summary
echo -e "${BLUE}=== Test Summary ===${NC}"
echo "All tests completed. Check the output directory for results:"
echo "$OUTPUT_DIR"
echo ""
echo "Output files generated:"
ls -la "$OUTPUT_DIR"/*.json 2>/dev/null || echo "No output files found"

echo ""
echo -e "${GREEN}Test suite completed!${NC}"
echo ""
echo "Next steps:"
echo "1. Review the generated XSD and Avro schemas in the output directory"
echo "2. Validate the XSD files against XML validators"
echo "3. Test Avro schemas with Avro tools or schema registry"
echo "4. Integrate the schemas into your data pipelines"
