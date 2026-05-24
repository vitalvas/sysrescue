#!/bin/bash

set -e -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
IMAGE_NAME="debian-iso-builder"

mkdir -p "${OUTPUT_DIR}"

echo "=== Building Docker image ==="
docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}"

echo "=== Building ISO ==="
docker run --privileged --rm \
    -v "${OUTPUT_DIR}:/output" \
    "${IMAGE_NAME}"

echo ""
echo "=== Output ==="
ls -lh "${OUTPUT_DIR}"/*.iso 2>/dev/null || echo "No ISO found in output/"
