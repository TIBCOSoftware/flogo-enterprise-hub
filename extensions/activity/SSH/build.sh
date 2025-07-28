#!/bin/bash

# Build script for TIBCO Flogo® Extension for SSH

set -e  # Exit on any error

cwd=`pwd`

echo "🚀 Building TIBCO Flogo® Extension for SSH..."
echo "============================================="
echo "$cwd"

# Download dependencies
echo "📦 Downloading dependencies..."
go clean -modcache
go mod tidy


# Build the activity
echo "🔨 Building activity..."
cd ./activity/run
go build -v .



# Run connector tests (if test dependencies are available)
echo "🧪 Running Flogo Connector tests..."
cd $cwd && cd ./connector/connection

if [ -f "connection_test.go" ]; then
    echo "🧹 Connection Go unit test detect. Run go test? (y/n)"
    read -r response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        echo "🧪 Running connector tests..."
        if go test -v ./...; then
            echo "✅ All connector tests passed!"
        else
            echo "⚠️ Tests failed or skipped - continuing with build"
        fi
    else
        echo "⚠️ Connection tests skipped"
    fi
fi


# Run activity tests (if test dependencies are available)
echo "🧪 Running Flogo Activity tests..."
cd $cwd && cd ./activity/run

if [ -f "activity_test.go" ]; then
    echo "🧹 Activity Go unit test detect. Run go test? (y/n)"
    read -r response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        echo "🧪 Running activity tests..."
        if go test -v ./...; then
            echo "✅ All activity tests passed!"
        else
            echo "⚠️ Tests failed or skipped - continuing with build"
        fi
    else
        echo "⚠️ Connection tests skipped"
    fi
fi


# Check for successful build
if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Activity build successful!"
    echo ""
    echo "📋 Next Steps:"
    echo "=============="
    echo "1. Clear Go module cache:     go clean -modcache"
    echo "2. Rebuild Flogo application: See instructions below"
    echo "3. Restart Flogo application"
    echo ""
    echo "🔄 Flogo Application Rebuild Options:"
    echo "======================================"
    echo ""
    echo "Option A - Using flogobuild CLI:"
    echo "  cd /path/to/your/flogo/app"
    echo "  flogobuild build-exe -f your-app.json"
    echo "  # Or for specific platform:"
    echo "  flogobuild build-exe -f your-app.json -p linux/amd64"
    echo ""
    echo "Option B - Docker Build:"
    echo "  flogobuild build-docker-image -f your-app.json"
    echo ""
    echo "🔧 Integration Details:"
    echo "======================"
    echo "  Module Path: github.com/tibco/extensions/SSH/activity/run"
    echo "  Activity Category: #SSH"
    echo ""
    echo "📖 For detailed usage examples, see README.md"
    echo ""
    
    # Check if we're in a Flogo workspace and offer to clean cache
    if [ -f "../../go.mod" ] || [ -f "../go.mod" ]; then
        echo "🧹 Flogo workspace detected. Clean module cache? (y/n)"
        read -r response
        if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            echo "🧹 Cleaning Go module cache..."
            go clean -modcache
            echo "✅ Module cache cleaned!"
        fi
    fi
    
    # Check if there are Flogo binaries to rebuild
    if [ -d "../../bin" ] && [ "$(ls -A ../../bin)" ]; then
        echo ""
        echo "🔍 Flogo binaries found in ../../bin/"
        echo "📋 Consider rebuilding these applications:"
        ls -1 ../../bin/ | grep -v "\\.sh$" | sed 's/^/  - /'
        echo ""
        echo "💡 To rebuild, remove the binary and rebuild your Flogo application"
    fi
else
    echo ""
    echo "❌ Build failed!"
    echo ""
    echo "🔍 Troubleshooting:"
    echo "=================="
    echo "1. Check Go version: go version (requires Go 1.19+)"
    echo "2. Verify dependencies: go mod tidy"
    echo "3. Check for syntax errors in activity.go"
    echo "4. Ensure all imports are available"
    echo ""
    exit 1
fi