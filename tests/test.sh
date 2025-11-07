#!/bin/bash

# Comprehensive test script for Grafana Observability Stack
# Tests API functionality and service connectivity

set -e

# Ensure region is set
REGION=${AWS_DEFAULT_REGION:-$(aws configure get region)}
if [ -z "$REGION" ]; then
    REGION="us-west-2"
    echo "⚠️  No region configured, defaulting to us-west-2"
fi

echo "🧪 Testing Grafana Observability Stack in region: $REGION"
echo "=================================================="

# Get endpoints from CDK outputs
echo "📡 Getting service endpoints..."
API_ENDPOINT=$(aws cloudformation describe-stacks \
  --region $REGION \
  --stack-name GrafanaObservabilityStackStack \
  --query 'Stacks[0].Outputs[?OutputKey==`APIEndpoint`].OutputValue' \
  --output text 2>/dev/null)

DATA_PROCESSOR_ENDPOINT=$(aws cloudformation describe-stacks \
  --region $REGION \
  --stack-name GrafanaObservabilityStackStack \
  --query 'Stacks[0].Outputs[?OutputKey==`DataProcessorEndpoint`].OutputValue' \
  --output text 2>/dev/null)

METRICS_ENDPOINT=$(aws cloudformation describe-stacks \
  --region $REGION \
  --stack-name GrafanaObservabilityStackStack \
  --query 'Stacks[0].Outputs[?OutputKey==`MetricsEndpoint`].OutputValue' \
  --output text 2>/dev/null)

LOKI_LB_DNS=$(aws cloudformation describe-stacks \
  --region $REGION \
  --stack-name GrafanaObservabilityStackStack \
  --query 'Stacks[0].Outputs[?OutputKey==`LokiLoadBalancerDNS`].OutputValue' \
  --output text 2>/dev/null)

TEMPO_LB_DNS=$(aws cloudformation describe-stacks \
  --region $REGION \
  --stack-name GrafanaObservabilityStackStack \
  --query 'Stacks[0].Outputs[?OutputKey==`TempoLoadBalancerDNS`].OutputValue' \
  --output text 2>/dev/null)

if [ -z "$DATA_PROCESSOR_ENDPOINT" ]; then
  echo "❌ Could not find service endpoints. Make sure the stack is deployed."
  exit 1
fi

echo "📊 Service Endpoints:"
echo "   Data Processor: $DATA_PROCESSOR_ENDPOINT"
echo "   Metrics: $METRICS_ENDPOINT"
echo "   Loki: http://$LOKI_LB_DNS:3100"
echo "   Tempo: http://$TEMPO_LB_DNS:3200"
echo ""

# Test API functionality
echo "🔧 Testing API Functionality"
echo "=============================="

# Test 1: Health check
echo "❤️  Health check..."
HEALTH=$(curl -s --max-time 10 --max-time 10 "${DATA_PROCESSOR_ENDPOINT}/health")
if echo "$HEALTH" | jq -e '.status' > /dev/null 2>&1; then
  echo "✅ Health check passed"
else
  echo "❌ Health check failed: $HEALTH"
fi

# Test 2: Store data
echo "📝 Storing test data..."
RESPONSE=$(curl -s --max-time 10 --max-time 10 -X POST "${DATA_PROCESSOR_ENDPOINT}/data" \
  -H "Content-Type: application/json" \
  -d '{"message": "Test data", "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'", "value": 42}')

KEY=$(echo $RESPONSE | jq -r '.key' 2>/dev/null)
if [ "$KEY" != "null" ] && [ -n "$KEY" ]; then
  echo "✅ Data stored successfully with key: $KEY"
  
  # Test 3: Retrieve data
  echo "📖 Retrieving stored data..."
  RETRIEVED=$(curl -s --max-time 10 --max-time 10 "${DATA_PROCESSOR_ENDPOINT}/data/${KEY}")
  if echo "$RETRIEVED" | jq -e '.message' > /dev/null 2>&1; then
    echo "✅ Data retrieved successfully"
  else
    echo "❌ Failed to retrieve data: $RETRIEVED"
  fi
else
  echo "❌ Failed to store data: $RESPONSE"
fi

# Test 4: Get metrics
echo "📊 Testing metrics endpoint..."
# Use port 80 instead of 9090 since metrics are on the main app port
METRICS=$(curl -s --max-time 10 "${DATA_PROCESSOR_ENDPOINT}/metrics")
if echo "$METRICS" | grep -q "doc_operations_total"; then
  echo "✅ Metrics endpoint working (doc_operations_total found)"
else
  echo "❌ Metrics endpoint not working"
fi

# Test 5: Test 404
echo "🔍 Testing 404 handling..."
NOT_FOUND=$(curl -s --max-time 10 --max-time 10 "${DATA_PROCESSOR_ENDPOINT}/data/nonexistent")
if echo "$NOT_FOUND" | jq -e '.error' > /dev/null 2>&1; then
  echo "✅ 404 handling working"
else
  echo "❌ 404 handling not working"
fi

echo ""

# Test service connectivity
echo "🌐 Testing Service Connectivity"
echo "==============================="

# Test Loki connectivity
echo "🔍 Testing Loki connectivity..."
LOKI_URL="http://$LOKI_LB_DNS:3100"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "$LOKI_URL/ready" 2>/dev/null || echo "000")
if [ "$HTTP_STATUS" = "200" ]; then
    echo "✅ Loki is reachable ($LOKI_URL)"
else
    echo "❌ Loki is not reachable ($LOKI_URL) - Status: $HTTP_STATUS"
fi

# Test Tempo connectivity
echo "🔍 Testing Tempo connectivity..."
TEMPO_URL="http://$TEMPO_LB_DNS:3200"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "$TEMPO_URL/status" 2>/dev/null || echo "000")
if [ "$HTTP_STATUS" = "200" ]; then
    echo "✅ Tempo is reachable ($TEMPO_URL)"
else
    echo "❌ Tempo is not reachable ($TEMPO_URL) - Status: $HTTP_STATUS"
fi

echo ""
echo "🎉 Testing complete!"
echo ""
echo "💡 Next steps:"
echo "   1. Access Grafana dashboard via AWS Console"
echo "   2. Import dashboards from ./dashboards/ directory"
echo "   3. Run this test script periodically to generate sample data"
