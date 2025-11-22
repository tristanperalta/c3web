#!/bin/bash

# Autobahn WebSocket Testsuite Runner
# Validates c3web WebSocket implementation against 500+ RFC 6455 conformance tests

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Autobahn WebSocket Testsuite ===${NC}\n"

# Get project root directory
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUTOBAHN_DIR="$PROJECT_ROOT/test/autobahn"

cd "$PROJECT_ROOT"

# Build library and server
echo -e "${YELLOW}Building c3web library...${NC}"
c3c build c3web || {
    echo -e "${RED}[ERROR] Failed to build c3web library${NC}"
    exit 1
}

echo -e "${YELLOW}Building WebSocket echo server...${NC}"
c3c build autobahn_server || {
    echo -e "${RED}[ERROR] Failed to build autobahn_server${NC}"
    exit 1
}

echo -e "${GREEN}[OK] Build complete${NC}\n"

# Start WebSocket server in background
echo -e "${YELLOW}Starting WebSocket echo server on port 9002...${NC}"
./build/autobahn_server > /tmp/autobahn_server.log 2>&1 &
SERVER_PID=$!

# Ensure server gets killed on script exit
trap "kill $SERVER_PID 2>/dev/null || true; rm -f /tmp/autobahn_server.log" EXIT

# Wait for server to be ready
echo "Waiting for server to start..."
MAX_WAIT=10
WAITED=0

while [ $WAITED -lt $MAX_WAIT ]; do
    if grep -q "\[READY\]" /tmp/autobahn_server.log 2>/dev/null; then
        echo -e "${GREEN}[OK] Server is ready${NC}\n"
        break
    fi
    sleep 0.5
    WAITED=$((WAITED + 1))
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo -e "${RED}[ERROR] Server failed to start within ${MAX_WAIT} seconds${NC}"
    echo "Server log:"
    cat /tmp/autobahn_server.log
    exit 1
fi

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo -e "${RED}[ERROR] Docker is not installed or not in PATH${NC}"
    echo "Please install Docker to run Autobahn testsuite"
    echo "See: https://docs.docker.com/get-docker/"
    exit 1
fi

# Run Autobahn testsuite
echo -e "${YELLOW}Running Autobahn testsuite (500+ test cases)...${NC}"
echo "This may take several minutes..."
echo ""

cd "$AUTOBAHN_DIR"

# Create reports directory if it doesn't exist
mkdir -p reports

# Run Docker container with Autobahn testsuite
docker run --rm \
  -v "${AUTOBAHN_DIR}/fuzzingclient.json:/config/fuzzingclient.json" \
  -v "${AUTOBAHN_DIR}/reports:/reports" \
  --add-host=host.docker.internal:host-gateway \
  crossbario/autobahn-testsuite:latest \
  wstest -m fuzzingclient -s /config/fuzzingclient.json

echo ""
echo -e "${GREEN}=== Autobahn Testsuite Complete ===${NC}"
echo ""

# Check if report exists and run results checker
if [ -f "${AUTOBAHN_DIR}/reports/index.json" ]; then
    # Run the Python results checker for detailed analysis
    if [ -f "${AUTOBAHN_DIR}/check_results.py" ]; then
        python3 "${AUTOBAHN_DIR}/check_results.py" --failed --details
    else
        echo -e "${YELLOW}[WARN] check_results.py not found, showing basic summary${NC}"
    fi

    echo ""
    echo -e "${BLUE}Reports:${NC}"
    echo "  HTML Report: ${AUTOBAHN_DIR}/reports/index.html"
    echo "  JSON Report: ${AUTOBAHN_DIR}/reports/index.json"
    echo ""
    echo "To view detailed HTML report:"
    echo "  xdg-open ${AUTOBAHN_DIR}/reports/index.html    # Linux"
    echo "  open ${AUTOBAHN_DIR}/reports/index.html        # macOS"
    echo ""
    echo "To run results checker manually:"
    echo "  ./check_results.py              # Summary"
    echo "  ./check_results.py --all        # All tests"
    echo "  ./check_results.py --failed -d  # Failed tests with details"
    echo "  ./check_results.py -c 12        # Compression tests only"
else
    echo -e "${RED}[ERROR] Test report not generated${NC}"
    exit 1
fi
