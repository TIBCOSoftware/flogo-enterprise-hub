#!/usr/bin/env bash
set -e

echo "=========================================================="
echo "  Starting ActiveSpace Connector Flogo App"
echo "  Host: $HOSTNAME"
echo "  Logs: /app/logs/${HOSTNAME}/flogoapp/"
echo "=========================================================="

# Create log folder
mkdir -p /app/logs/${HOSTNAME}/flogoapp

# Export environment variables
export FLOGO_FILES_ROOT_DIR="${FLOGO_FILES_ROOT_DIR:-/tmp/flogo}"

# ActiveSpaces + FTL library paths
export LD_LIBRARY_PATH="/opt/tibco/as/4.10/lib:/opt/tibco/ActiveSpaceConnector/lib:/opt/tibco/ftl/7.0/lib:/usr/lib64:/lib64:$LD_LIBRARY_PATH"

echo "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
echo "----------------------------------------------------------"

# Ensure rotatelogs exists
if ! command -v rotatelogs >/dev/null 2>&1; then
  echo "ERROR: rotatelogs not found. Install httpd-tools in Dockerfile."
  exit 1
fi

# Run the application with log rotation
./activespaceapp 2>&1 | tee >(
  rotatelogs -t /app/logs/${HOSTNAME}/flogoapp/otel.log 10M
)
