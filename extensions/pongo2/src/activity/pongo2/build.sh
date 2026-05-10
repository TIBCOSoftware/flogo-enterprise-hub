#!/bin/bash

# Build script for pongo2 Flogo activity
# This script builds the activity and creates a deployment-ready package

echo "Building pongo2 Flogo activity..."

# Clean previous builds
echo "Cleaning previous builds..."
go clean
rm -f pongo2 pongo2.so

# Run tests first
echo "Running tests..."
go test -v
if [ $? -ne 0 ]; then
    echo "Tests failed. Aborting build."
    exit 1
fi

# Build the activity (as a library, not a plugin)
echo "Building activity library..."
go build .
if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

echo "Activity library built successfully!"
echo "This activity is ready to be imported as a Go module in Flogo applications."

echo "Build completed successfully!"
echo ""
echo "Activity is ready for use in Flogo applications!"
echo ""
echo "Deployment instructions:"
echo "1. Import this activity in your Flogo application by referencing the module"
echo "2. Use the activity with the enhanced UI features:"
echo "   - Large textarea (15 rows) for template editing"
echo "   - Single 'variables' input for all template variables"
echo "   - Comprehensive logging and validation"
echo "   - Automatic template variable detection"
echo ""
echo "Example go.mod reference:"
echo "replace github.com/your-org/pongo2 => /path/to/this/directory"