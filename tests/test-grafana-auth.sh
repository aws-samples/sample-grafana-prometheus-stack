#!/bin/bash
set -e

REGION=${AWS_DEFAULT_REGION:-us-west-2}

echo "🧪 Testing Grafana Prometheus Authentication"
echo "============================================="

GRAFANA_URL=$(aws cloudformation describe-stacks \
  --stack-name GrafanaObservabilityStackStack \
  --region $REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`GrafanaURL`].OutputValue' \
  --output text)

if [ -z "$GRAFANA_URL" ]; then
    echo "❌ Stack not deployed or Grafana URL not found"
    exit 1
fi

echo "📡 Grafana URL: $GRAFANA_URL"

# Get datasource UID
DS_UID=$(curl -s "$GRAFANA_URL/api/datasources" -u admin:admin | jq -r '.[] | select(.name=="Prometheus") | .uid')

if [ -z "$DS_UID" ]; then
    echo "❌ Prometheus datasource not found"
    exit 1
fi

echo "✅ Datasource UID: $DS_UID"

# Test query
echo "🔍 Testing Prometheus query..."
RESPONSE=$(curl -s "$GRAFANA_URL/api/datasources/uid/$DS_UID/resources/api/v1/query?query=up" -u admin:admin)

if echo "$RESPONSE" | grep -q "Missing Authentication Token"; then
    echo "❌ Authentication failed: $RESPONSE"
    exit 1
elif echo "$RESPONSE" | grep -q '"status":"success"'; then
    echo "✅ Authentication successful!"
    echo "$RESPONSE" | jq -r '.status'
    exit 0
else
    echo "⚠️  Unexpected response: $RESPONSE"
    exit 1
fi
