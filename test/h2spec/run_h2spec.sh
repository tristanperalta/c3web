#!/bin/bash

# h2spec HTTP/2 Conformance Testsuite Runner
# Validates c3web HTTP/2 implementation against RFC 9113 compliance tests

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== h2spec HTTP/2 Conformance Testsuite ===${NC}\n"

# Get project root directory
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H2SPEC_DIR="$PROJECT_ROOT/test/h2spec"
H2SPEC_PORT="${H2SPEC_PORT:-8080}"

cd "$PROJECT_ROOT"

# Parse arguments - pass through to h2spec
H2SPEC_EXTRA_ARGS=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            echo "Usage: $0 [h2spec options]"
            echo ""
            echo "Common options:"
            echo "  --strict       Run in strict mode"
            echo "  -S, --section  Run specific section (e.g., -S 3, -S 6.5)"
            echo "  -v, --verbose  Verbose output"
            echo "  -h, --help     Show this help"
            echo ""
            echo "Environment variables:"
            echo "  H2SPEC_PORT    Port for HTTP/2 server (default: 8080)"
            exit 0
            ;;
        *)
            H2SPEC_EXTRA_ARGS="$H2SPEC_EXTRA_ARGS $1"
            shift
            ;;
    esac
done

# Build library and server
echo -e "${YELLOW}Building c3web library...${NC}"
c3c build c3web || {
    echo -e "${RED}[ERROR] Failed to build c3web library${NC}"
    exit 1
}

echo -e "${YELLOW}Building HTTP/2 test server...${NC}"
c3c build h2spec_server || {
    echo -e "${RED}[ERROR] Failed to build h2spec_server${NC}"
    exit 1
}

echo -e "${GREEN}[OK] Build complete${NC}\n"

# Start HTTP/2 server in background
echo -e "${YELLOW}Starting HTTP/2 server on port ${H2SPEC_PORT}...${NC}"
./build/h2spec_server > /tmp/h2spec_server.log 2>&1 &
SERVER_PID=$!

# Ensure server gets killed on script exit
trap "kill $SERVER_PID 2>/dev/null || true" EXIT

# Wait for server to be ready
echo "Waiting for server to start..."
MAX_WAIT=10
WAITED=0

while [ $WAITED -lt $MAX_WAIT ]; do
    if grep -q "\[READY\]" /tmp/h2spec_server.log 2>/dev/null; then
        echo -e "${GREEN}[OK] Server is ready${NC}\n"
        break
    fi
    sleep 0.5
    WAITED=$((WAITED + 1))
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo -e "${RED}[ERROR] Server failed to start within ${MAX_WAIT} seconds${NC}"
    echo "Server log:"
    cat /tmp/h2spec_server.log
    exit 1
fi

# Find h2spec binary (prefer local over Docker)
if command -v h2spec &> /dev/null; then
    H2SPEC_CMD="h2spec"
    echo -e "${GREEN}Using local h2spec: $(which h2spec)${NC}"
elif command -v docker &> /dev/null; then
    H2SPEC_CMD="docker run --rm --network=host summerwind/h2spec:latest h2spec"
    echo -e "${YELLOW}Using Docker h2spec${NC}"
else
    echo -e "${RED}[ERROR] h2spec not found. Install h2spec or Docker.${NC}"
    echo "Download from: https://github.com/summerwind/h2spec/releases"
    exit 1
fi

# Run h2spec testsuite
echo -e "${YELLOW}Running h2spec conformance tests...${NC}"
echo ""

$H2SPEC_CMD -p $H2SPEC_PORT $H2SPEC_EXTRA_ARGS

RESULT=$?

echo ""
echo -e "${GREEN}=== h2spec Testsuite Complete ===${NC}"
echo ""
echo "To run specific sections:"
echo "  $0 -S 3           # Section 3: Starting HTTP/2"
echo "  $0 -S 6.5         # Section 6.5: SETTINGS"
echo "  $0 --strict       # Strict mode"
echo "  $0 -v             # Verbose output"

exit $RESULT
