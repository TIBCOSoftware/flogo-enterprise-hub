#!/usr/bin/env bash

mkdir -p /app/logs/${HOSTNAME}/flogoapp

export FLOGO_FILES_ROOT_DIR="${FLOGO_FILES_ROOT_DIR:-/tmp/flogo}"
./flogo-oracle 2>&1 | tee >(rotatelogs -t /app/logs/${HOSTNAME}/flogoapp/otel.log 10M)