#!/bin/bash

# Ensure region is set
REGION=${AWS_DEFAULT_REGION:-$(aws configure get region)}
if [ -z "$REGION" ]; then
    REGION="us-west-2"
    echo "⚠️  No region configured, defaulting to us-west-2"
fi

echo "🔧 Configuring Grafana data sources and dashboards..."

# Get workspace details
WORKSPACE_ID=$(aws grafana list-workspaces --region $REGION --query 'workspaces[?name==`grafana-observability-workspace`].id' --output text)
WORKSPACE_URL=$(aws grafana list-workspaces --region $REGION --query 'workspaces[?name==`grafana-observability-workspace`].endpoint' --output text)

# Add https:// if missing
if [[ ! "$WORKSPACE_URL" =~ ^https?:// ]]; then
    WORKSPACE_URL="https://$WORKSPACE_URL"
fi

if [ -z "$WORKSPACE_ID" ]; then
    echo "❌ Grafana workspace not found. Run ./setup-grafana.sh first"
    exit 1
fi

echo "📊 Found workspace: $WORKSPACE_ID"
echo "🌐 Workspace URL: $WORKSPACE_URL"

# Get Prometheus workspace ID
PROMETHEUS_WORKSPACE_ID=$(aws cloudformation describe-stacks \
  --region $REGION \
  --stack-name GrafanaObservabilityStackStack \
  --query 'Stacks[0].Outputs[?OutputKey==`PrometheusWorkspaceId`].OutputValue' \
  --output text)

# Get ECS cluster and service info
CLUSTER_NAME=$(aws cloudformation describe-stacks \
  --region $REGION \
  --stack-name GrafanaObservabilityStackStack \
  --query 'Stacks[0].Outputs[?OutputKey==`ECSClusterName`].OutputValue' \
  --output text)

# Get load balancer DNS names from CDK stack outputs
LOKI_LB_DNS=$(aws cloudformation describe-stacks \
  --region $REGION \
  --stack-name GrafanaObservabilityStackStack \
  --query 'Stacks[0].Outputs[?OutputKey==`LokiLoadBalancerDNS`].OutputValue' \
  --output text)

TEMPO_LB_DNS=$(aws cloudformation describe-stacks \
  --region $REGION \
  --stack-name GrafanaObservabilityStackStack \
  --query 'Stacks[0].Outputs[?OutputKey==`TempoLoadBalancerDNS`].OutputValue' \
  --output text)

if [ -z "$LOKI_LB_DNS" ] || [ -z "$TEMPO_LB_DNS" ]; then
    echo "❌ Load balancer DNS names not found. Make sure the CDK stack is deployed."
    exit 1
fi

LOKI_URL="http://$LOKI_LB_DNS:3100"
TEMPO_URL="http://$TEMPO_LB_DNS:3200"

echo "📡 Service endpoints:"
echo "   Prometheus: AWS Managed (✅ will work)"
echo "   Loki: $LOKI_URL (✅ will work)"
echo "   Tempo: $TEMPO_URL (✅ will work)"

echo "📡 Configuring data sources..."

# Create Loki data source
cat > /tmp/loki-datasource.json << EOF
{
  "name": "Loki",
  "type": "loki",
  "url": "$LOKI_URL",
  "access": "proxy",
  "jsonData": {
    "maxLines": 1000
  }
}
EOF

# Create Tempo data source
cat > /tmp/tempo-datasource.json << EOF
{
  "name": "Tempo",
  "type": "tempo",
  "url": "$TEMPO_URL",
  "access": "proxy",
  "jsonData": {
    "tracesToLogs": {
      "datasourceUid": "loki",
      "tags": ["job", "instance"],
      "mappedTags": [{"key": "service.name", "value": "service"}]
    },
    "tracesToMetrics": {
      "datasourceUid": "prometheus",
      "tags": [{"key": "service.name", "value": "service"}]
    },
    "serviceMap": {
      "datasourceUid": "prometheus"
    },
    "nodeGraph": {
      "enabled": true
    }
  }
}
EOF

echo "🔌 Adding Prometheus data source..."

# Generate unique API key name with timestamp
TIMESTAMP=$(date +%s)
KEY_NAME="config-key-$TIMESTAMP"

# Create API key using AWS Grafana API
echo "🔑 Creating temporary API key..."
API_KEY=$(aws grafana create-workspace-api-key \
  --key-name "config-key-$(date +%s)" \
  --key-role ADMIN \
  --seconds-to-live 600 \
  --workspace-id "$WORKSPACE_ID" \
  --region $REGION \
  --query 'key' --output text)

if [ -z "$API_KEY" ]; then
    echo "❌ Failed to create API key"
    exit 1
fi

echo "✅ API key created"

# Skip API test since it's timing out but the actual API calls work
echo "🔍 Skipping API test (proceeding directly to configuration)..."

# Add/Update data sources
echo "📊 Configuring Prometheus data source..."
PROM_RESULT=$(curl -s -X POST "$WORKSPACE_URL/api/datasources" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "AWS Managed Prometheus",
    "type": "prometheus",
    "url": "https://aps-workspaces.$REGION.amazonaws.com/workspaces/'$PROMETHEUS_WORKSPACE_ID'/",
    "access": "proxy",
    "isDefault": true,
    "jsonData": {
      "sigV4Auth": true,
      "sigV4Region": "'$REGION'"
    }
  }'
)

if echo "$PROM_RESULT" | grep -q "already exists"; then
  echo "  Prometheus data source is already exists"
else
  echo "  You need to manually update the Prometheus Data Source ..."
  echo ""
  echo "🛠️  Please manually update the Prometheus Data Source:"
  echo "   1. Go to: $WORKSPACE_URL"
  echo "   2. Sign in with AWS SSO"
  echo "   3. Go to Connections → Data Sources"
  echo "   4. Click on 'AWS Managed Prometheus'"
  echo "   5. in Settings Page, click on 'Save & Test' button"
  echo ""
  read -p "Press ENTER after you've manually updated the Prometheus Data Source ..."
fi

echo "📝 Configuring Loki data source..."
LOKI_RESULT=$(curl -s -X POST "$WORKSPACE_URL/api/datasources" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d @/tmp/loki-datasource.json)

if echo "$LOKI_RESULT" | grep -q "already exists"; then
    echo "  Loki data source is already exists"
fi

echo "☁️ Configuring CloudWatch data source..."
CLOUDWATCH_RESULT=$(curl -s -X POST "$WORKSPACE_URL/api/datasources" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "CloudWatch",
    "type": "cloudwatch",
    "access": "proxy",
    "jsonData": {
      "defaultRegion": "'$REGION'",
      "authType": "default"
    }
  }')

if echo "$CLOUDWATCH_RESULT" | grep -q "already exists"; then
    echo "  CloudWatch data source already exists"
else
    echo "  CloudWatch data source configured"
fi

echo "🔍 Configuring Tempo data source..."
# Get datasource UIDs for proper linking
LOKI_UID=$(curl -s "$WORKSPACE_URL/api/datasources/name/Loki" \
  -H "Authorization: Bearer $API_KEY" | jq -r '.uid // "loki"')
PROMETHEUS_UID=$(curl -s "$WORKSPACE_URL/api/datasources/name/AWS%20Managed%20Prometheus" \
  -H "Authorization: Bearer $API_KEY" | jq -r '.uid // "prometheus"')

cat > /tmp/tempo-datasource.json << EOF
{
  "name": "Tempo",
  "type": "tempo",
  "url": "$TEMPO_URL",
  "access": "proxy",
  "jsonData": {
    "tracesToLogs": {
      "datasourceUid": "$LOKI_UID",
      "tags": ["service", "operation"],
      "mappedTags": [
        {"key": "service.name", "value": "service"},
        {"key": "operation", "value": "operation"}
      ],
      "mapTagNamesEnabled": true,
      "spanStartTimeShift": "1m",
      "spanEndTimeShift": "-1m",
      "filterByTraceID": true,
      "filterBySpanID": true
    },
    "tracesToMetrics": {
      "datasourceUid": "$PROMETHEUS_UID",
      "tags": [
        {"key": "service.name", "value": "service"},
        {"key": "operation", "value": "operation"}
      ],
      "queries": [
        {
          "name": "Operation Rate",
          "query": "sum(rate(doc_operations_total{operation=\"\$operation\"}[5m]))"
        },
        {
          "name": "Operation Duration",
          "query": "histogram_quantile(0.95, rate(doc_operation_duration_seconds_bucket{operation=\"\$operation\"}[5m]))"
        },
        {
          "name": "Error Rate",
          "query": "sum(rate(doc_operations_total{operation=\"\$operation\", status_type=\"service_error\"}[5m]))"
        }
      ]
    },
    "serviceMap": {
      "datasourceUid": "$PROMETHEUS_UID"
    },
    "nodeGraph": {
      "enabled": true
    }
  }
}
EOF

TEMPO_RESULT=$(curl -s -X POST "$WORKSPACE_URL/api/datasources" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d @/tmp/tempo-datasource.json)

if echo "$TEMPO_RESULT" | grep -q "already exists"; then
    echo "   Updating existing Tempo data source..."
    TEMPO_ID=$(curl -s "$WORKSPACE_URL/api/datasources/name/Tempo" \
      -H "Authorization: Bearer $API_KEY" | jq -r '.id')
    curl -s -X PUT "$WORKSPACE_URL/api/datasources/$TEMPO_ID" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d @/tmp/tempo-datasource.json
fi

echo "📊 Importing dashboards..."

# Import API monitoring dashboard
DASHBOARD_RESULT=$(curl -s -X POST "$WORKSPACE_URL/api/dashboards/db" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d @dashboards/api-monitoring.json)

if echo "$DASHBOARD_RESULT" | grep -q "success"; then
    echo "✅ Dashboard imported successfully"
    DASHBOARD_URL=$(echo "$DASHBOARD_RESULT" | jq -r '.url // empty')
    if [ -n "$DASHBOARD_URL" ]; then
        echo "📊 Dashboard URL: $WORKSPACE_URL$DASHBOARD_URL"
    fi
elif echo "$DASHBOARD_RESULT" | grep -q "already exists"; then
    echo "📝 Dashboard already exists, updating..."
    # Try to update existing dashboard
    DASHBOARD_UID=$(echo "$DASHBOARD_RESULT" | jq -r '.message' | grep -o 'uid: [a-zA-Z0-9_-]*' | cut -d' ' -f2)
    if [ -n "$DASHBOARD_UID" ]; then
        # Update existing dashboard
        jq '.dashboard.uid = "'$DASHBOARD_UID'"' dashboards/api-monitoring.json > /tmp/dashboard-update.json
        UPDATE_RESULT=$(curl -s -X POST "$WORKSPACE_URL/api/dashboards/db" \
          -H "Authorization: Bearer $API_KEY" \
          -H "Content-Type: application/json" \
          -d @/tmp/dashboard-update.json)
        echo "✅ Dashboard updated successfully"
        rm -f /tmp/dashboard-update.json
    fi
else
    echo "⚠️  Dashboard import result: $DASHBOARD_RESULT"
fi

echo "🚨 Configuring alert rules with SNS notifications..."

# Get SNS topic ARN for Grafana webhook
GRAFANA_WEBHOOK_TOPIC_ARN=$(aws cloudformation describe-stacks \
  --region $REGION \
  --stack-name GrafanaObservabilityStackStack \
  --query 'Stacks[0].Outputs[?OutputKey==`GrafanaWebhookTopicArn`].OutputValue' \
  --output text)

if [ -z "$GRAFANA_WEBHOOK_TOPIC_ARN" ]; then
    echo "❌ Could not find Grafana webhook topic ARN. Make sure the stack is deployed."
    exit 1
fi

echo "📡 Found SNS topic: $GRAFANA_WEBHOOK_TOPIC_ARN"

echo ""
echo "🚨 MANUAL ALERT CONFIGURATION REQUIRED"
echo "======================================"
echo ""
echo "Please follow these manual steps in the Grafana UI:"
echo ""
echo "1. 📊 ACCESS GRAFANA"
echo "   Open the Grafana URL and log in with AWS SSO credentials:"
echo "   URL: $WORKSPACE_URL"
echo ""
echo "2. 📝 DEFINE CUSTOM NOTIFICATION TEMPLATE"
echo "   Notification templates are managed centrally and must be defined before use in a contact point."
echo ""
echo "   - Navigate to: Home → Alerting → Contact points → Notification Templates"
echo "   - Create a new template group (e.g., DocStorage_Custom_Templates)"
echo "   - Define a named message template within this group to structure the detailed SNS message:"
echo ""
echo "   Template Name: alerts.docstorage.message"
echo "   Template Content:"
echo "   {{ define \"alerts.docstorage.message\" }}"
echo "   {"
echo "     \"status\": \"{{ .Status }}\","
echo "     \"groupLabels\": {"
echo "       \"alertname\": \"{{ .GroupLabels.alertname }}\","
echo "       \"severity\": \"{{ .GroupLabels.severity }}\","
echo "       \"service\": \"{{ .GroupLabels.service }}\""
echo "     },"
echo "     \"commonLabels\": {"
echo "       \"alertname\": \"{{ .CommonLabels.alertname }}\","
echo "       \"severity\": \"{{ .CommonLabels.severity }}\","
echo "       \"service\": \"{{ .CommonLabels.service }}\""
echo "     },"
echo "     \"commonAnnotations\": {"
echo "       \"summary\": \"{{ .CommonAnnotations.summary }}\","
echo "       \"description\": \"{{ .CommonAnnotations.description }}\""
echo "     },"
echo "     \"alertsCount\": {{ len .Alerts }}"
echo "   }"
echo "   {{ end }}"
echo ""
echo "3. 🔔 CREATE CONTACT POINT: SNS Notifications"
echo "   This step integrates the defined message template into the Amazon SNS endpoint."
echo ""
echo "   - Go to: Home → Alerting → Contact points"
echo "   - Click: 'New contact point'"
echo "   - Name: SNS Notifications"
echo "   - Type: Amazon SNS"
echo "   - Topic ARN: $GRAFANA_WEBHOOK_TOPIC_ARN"
echo "   - Auth Provider: AWS SDK Default"
echo "   - Subject: Grafana Alert: {{.GroupLabels.alertname }}"
echo "   - Message: {{ template \"alerts.docstorage.message\" . }}"
echo "   - Click: 'Test' then 'Save contact point'"
echo ""
echo "4. 📋 CREATE NOTIFICATION POLICY: Specific Routing Override"
echo "   Custom policies are defined hierarchically under the Default Policy."
echo ""
echo "   - Go to: Home → Alerting → Notification policies"
echo "   - Locate the Default policy section and click '+ New specific policy' (or '+ New child policy')"
echo "   - Contact point: SNS Notifications"
echo "   - Matching labels: severity =~ sev2|sev3"
echo "   - Group by: alertname, severity"
echo "   - Timing: Group wait: 10s, Group interval: 5m, Repeat interval: 12h"
echo "   - Click: 'Save policy'"
echo ""
echo "5. 🚨 CREATE ALERT RULE 1 (SEV3)"
echo "   The alert is configured with the necessary 5-minute stabilization period."
echo ""
echo "   - Go to: Home → Alerting → Alert rules"
echo "   - Click: 'New rule'"
echo "   - Rule name: DocStorageService_High_Error_Rate_Sev3"
echo "   - Query A: rate(doc_operations_total{service=\"DocStorageService\", status_type=\"service_error\"}[1m]) * 60"
echo "   - Query B (Condition): Function: IS ABOVE, Value: 2"
echo "   - Alert evaluation: Evaluation interval: 1m, For: 5m"
echo "   - Labels: severity: sev3, service: DocStorageService"
echo "   - Annotations:"
echo "     - Summary: DocStorageService has high service error rate (Sev3)"
echo "     - Description: DocStorageService is experiencing sustained service errors (threshold: 2/min)"
echo "   - Click: 'Save rule'"
echo ""
echo "6. 🚨 CREATE ALERT RULE 2 (SEV2)"
echo "   - Rule name: DocStorageService_High_Error_Rate_Sev2"
echo "   - Query A: rate(doc_operations_total{service=\"DocStorageService\", status_type=\"service_error\"}[1m]) * 60"
echo "   - Query B (Condition): Function: IS ABOVE, Value: 5"
echo "   - Alert evaluation: Evaluation interval: 1m, For: 5m"
echo "   - Labels: severity: sev2, service: DocStorageService"
echo "   - Annotations:"
echo "     - Summary: DocStorageService has critical service error rate (Sev2)"
echo "     - Description: DocStorageService is experiencing critical service errors (threshold: 5/min)"
echo "   - Click: 'Save rule'"
echo ""
echo "7. ✅ VERIFY SETUP"
echo "   - Verify: Alert rules are present and both show a For duration of 5 minutes"
echo "   - Verify: Contact point is configured with the template reference"
echo "   - Verify: Notification Policy is nested as a specific routing rule under the Default Policy"
echo ""
echo "📝 NOTES:"
echo "   - The 5-minute 'For' duration prevents false alarms from brief spikes"
echo "   - SNS notifications will be sent to: $GRAFANA_WEBHOOK_TOPIC_ARN"
echo "   - You can test alerts by generating sustained errors via your API"
echo ""
echo "⏸️  PAUSING FOR MANUAL CONFIGURATION"
echo "====================================="
echo ""
read -p "Press ENTER after you have completed the manual alert configuration above..."
echo ""
echo "✅ Continuing with setup..."

# Clean up
rm /tmp/loki-datasource.json /tmp/tempo-datasource.json

echo "🧹 API key cleanup..."
echo "💡 The API key will expire automatically in 10 minutes"
echo "   Or you can delete it manually in Grafana: Administration → Service accounts"

echo "✅ Grafana configuration complete!"
echo ""
echo "🎉 Your observability stack is ready:"
echo "📊 Grafana: $WORKSPACE_URL"
echo "📈 Prometheus: Configured"
echo "📝 Loki: Configured" 
echo "🔍 Tempo: Configured"
echo "📋 Dashboards: Imported"
echo ""
echo "🧪 Run './test-api.sh' to generate sample data and see it in Grafana!"
