#!/bin/bash
# Test script for echo server

echo "Testing c3web Echo Server"
echo "========================="
echo ""

# Test 1: Simple GET request
echo "Test 1: Simple GET request"
echo "---------------------------"
curl -i http://localhost:8080/ 2>/dev/null
echo ""
echo ""

# Test 2: GET with custom headers and query parameters
echo "Test 2: GET with query parameters and custom headers"
echo "-----------------------------------------------------"
curl -i -H "X-Custom-Header: test-value" -H "User-Agent: c3web-test" "http://localhost:8080/test/path?foo=bar&name=c3web&id=123" 2>/dev/null
echo ""
echo ""

# Test 3: POST with body
echo "Test 3: POST with body"
echo "----------------------"
curl -i -X POST -H "Content-Type: application/json" -d '{"message": "Hello from c3web!"}' http://localhost:8080/api/echo 2>/dev/null
echo ""
echo ""

echo "Tests complete!"
