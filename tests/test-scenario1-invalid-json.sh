#!/bin/bash

# Ensure region is set
REGION=${AWS_DEFAULT_REGION:-$(aws configure get region)}
if [ -z "$REGION" ]; then
    REGION="us-west-2"
    echo "⚠️  No region configured, defaulting to us-west-2"
fi

# Get Data Processor endpoint from CDK outputs
DATA_PROCESSOR_ENDPOINT=$(aws cloudformation describe-stacks \
  --region $REGION \
  --stack-name GrafanaObservabilityStackStack \
  --query 'Stacks[0].Outputs[?OutputKey==`DataProcessorEndpoint`].OutputValue' \
  --output text)

if [ -z "$DATA_PROCESSOR_ENDPOINT" ]; then
  echo "❌ Could not find Data Processor endpoint. Make sure the stack is deployed."
  exit 1
fi

echo "🔥 Scenario 1: Testing Mixed Requests - 2 Failures + 2 Successes (Press Ctrl+C to stop)"
echo "   Data Processor: $DATA_PROCESSOR_ENDPOINT"

while true; do
  echo "$(date): Running mixed tests (2 failures + 2 successes)..."
  
  # 2 failure cases
  curl -s -X POST "${DATA_PROCESSOR_ENDPOINT}/data" \
    -H "Content-Type: application/json" \
    -d 'invalid-json-data' > /dev/null

  curl -s -X POST "${DATA_PROCESSOR_ENDPOINT}/data" \
    -H "Content-Type: application/json" \
    -d 'not json at all!!!' > /dev/null

  # 2 success cases
  curl -s -X POST "${DATA_PROCESSOR_ENDPOINT}/data" \
    -H "Content-Type: application/json" \
    -d '{"test": "success1", "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}' > /dev/null

  curl -s -X POST "${DATA_PROCESSOR_ENDPOINT}/data" \
    -H "Content-Type: application/json" \
    -d '{"test": "success2", "data": {"value": 42}}' > /dev/null

  echo "✅ 2 error + 2 success requests sent"
  sleep 5
done
