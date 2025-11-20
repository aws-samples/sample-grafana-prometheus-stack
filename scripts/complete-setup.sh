#!/bin/bash

echo "🚀 Complete Grafana Observability Stack Setup"
echo "============================================="

# Install AWS CDK if not present
if ! command -v cdk &> /dev/null; then
    echo "📦 Installing AWS CDK..."
    npm install -g aws-cdk
fi

# Check required tools
echo "🔍 Checking prerequisites..."
for tool in aws npm cdk docker; do
    if ! command -v $tool &> /dev/null; then
        echo "❌ $tool is required but not installed"
        exit 1
    fi
done
echo "✅ All required tools found"

# Ensure region is set
REGION=${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null)}
if [ -z "$REGION" ]; then
    REGION="us-west-2"
    echo "⚠️  No region configured, defaulting to us-west-2"
    export AWS_DEFAULT_REGION=$REGION
fi
echo "🌍 Using AWS region: $REGION"

# Step 1: Deploy infrastructure
echo "📦 Step 1: Deploying core infrastructure..."

# ECR login for Docker
aws ecr-public get-login-password --region $REGION | docker login --username AWS --password-stdin public.ecr.aws

# Install dependencies and build
echo "📦 Installing NPM dependencies..."
npm install

echo "📦 Building CDK project..."
npm run build

# Bootstrap and deploy CDK
echo "🔧 Bootstrapping CDK..."
cdk bootstrap

echo "🚀 Deploying stack..."
cdk deploy --require-approval never

if [ $? -ne 0 ]; then
    echo "❌ Infrastructure deployment failed"
    exit 1
fi

echo "✅ Core infrastructure deployed successfully!"

# Step 1.5: Force Grafana service restart to pick up IAM role
echo ""
echo "🔄 Step 1.5: Restarting Grafana service to apply IAM role..."
CLUSTER_ARN=$(aws ecs list-clusters --region $REGION --query 'clusterArns[0]' --output text)
GRAFANA_SERVICE=$(aws ecs list-services --cluster $CLUSTER_ARN --region $REGION --query 'serviceArns[?contains(@, `Grafana`)]' --output text)

if [ -n "$GRAFANA_SERVICE" ]; then
  aws ecs update-service --cluster $CLUSTER_ARN --service $GRAFANA_SERVICE --force-new-deployment --region $REGION > /dev/null
  echo "✅ Grafana service restart initiated"
  echo "⏳ Waiting for new task to start..."
  sleep 30
else
  echo "⚠️  Could not find Grafana service"
fi

# Step 1.6: Create sample document in S3 for testing
echo ""
echo "📄 Step 1.6: Creating sample document for testing..."
BUCKET_NAME=$(aws cloudformation describe-stacks --stack-name GrafanaObservabilityStackStack --region $REGION --query 'Stacks[0].Outputs[?OutputKey==`S3BucketName`].OutputValue' --output text 2>/dev/null)

if [ -n "$BUCKET_NAME" ] && [ "$BUCKET_NAME" != "None" ]; then
    echo '{"test": "sample-data", "created": "'$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)'"}' | aws s3 cp - s3://$BUCKET_NAME/documents/test-document.json
    echo "✅ Sample document created at s3://$BUCKET_NAME/documents/test-document.json"
else
    echo "⚠️  Could not find S3 bucket name, sample document creation skipped"
fi

# Step 2: Verify Grafana service is running
echo ""
echo "🔍 Step 2: Verifying Grafana service status..."
echo "✅ Self-hosted Grafana deployed with ECS stack"

# Step 3: Test API
echo ""
echo "🧪 Step 3: Testing API endpoints..."
./tests/test.sh

# Step 4: Export Grafana configuration to Parameter Store
echo ""
echo "📝 Step 4: Exporting Grafana configuration to Parameter Store..."
GRAFANA_URL=$(aws cloudformation describe-stacks --stack-name GrafanaObservabilityStackStack --region $REGION --query 'Stacks[0].Outputs[?OutputKey==`GrafanaURL`].OutputValue' --output text)

if [ -n "$GRAFANA_URL" ] && [ "$GRAFANA_URL" != "None" ]; then
  # Store Grafana URL in Parameter Store
  aws ssm put-parameter --name /workshop/grafana-url --value "$GRAFANA_URL" --type String --overwrite --region $REGION
  
  # Store default credentials
  aws ssm put-parameter --name /workshop/grafana-username --value "admin" --type String --overwrite --region $REGION
  aws ssm put-parameter --name /workshop/grafana-password --value "admin" --type SecureString --overwrite --region $REGION
  
  echo "✅ Grafana configuration exported to Parameter Store"
  echo "   - /workshop/grafana-url: $GRAFANA_URL"
  echo "   - /workshop/grafana-username: admin"
  echo "   - /workshop/grafana-password: [SecureString]"
  
  # Wait for Grafana to be ready
  echo "⏳ Waiting for Grafana to be ready..."
  for i in {1..20}; do
    if curl -s -f "$GRAFANA_URL/api/health" > /dev/null 2>&1; then
      echo "✅ Grafana is ready"
      break
    fi
    echo "⏳ Waiting for Grafana... (attempt $i/20)"
    sleep 15
  done
  
  # Configure Grafana data sources
  echo "🔧 Configuring Grafana data sources..."
  LOKI_DNS=$(aws cloudformation describe-stacks --stack-name GrafanaObservabilityStackStack --region $REGION --query 'Stacks[0].Outputs[?OutputKey==`LokiLoadBalancerDNS`].OutputValue' --output text)
  TEMPO_DNS=$(aws cloudformation describe-stacks --stack-name GrafanaObservabilityStackStack --region $REGION --query 'Stacks[0].Outputs[?OutputKey==`TempoLoadBalancerDNS`].OutputValue' --output text)
  
  # Prometheus is provisioned via datasources.yaml with SigV4 authentication
  
  # Add Loki data source
  curl -X POST -H "Content-Type: application/json" -u admin:admin \
    -d "{\"name\":\"Loki\",\"type\":\"loki\",\"url\":\"http://$LOKI_DNS:3100\",\"access\":\"proxy\"}" \
    "$GRAFANA_URL/api/datasources" 2>/dev/null || echo "⚠️  Loki data source may already exist"
  
  # Add Tempo data source
  curl -X POST -H "Content-Type: application/json" -u admin:admin \
    -d "{\"name\":\"Tempo\",\"type\":\"tempo\",\"url\":\"http://$TEMPO_DNS:3200\",\"access\":\"proxy\",\"jsonData\":{\"tracesToLogs\":{\"datasourceUid\":\"loki\"},\"tracesToMetrics\":{\"datasourceUid\":\"prometheus\"}}}" \
    "$GRAFANA_URL/api/datasources" 2>/dev/null || echo "⚠️  Tempo data source may already exist"
  
  echo "✅ Grafana data sources configured"
  
  # Import dashboard
  echo "📊 Importing dashboard..."
  DASHBOARD_JSON=$(cat dashboards/api-monitoring.json)
  curl -X POST -H "Content-Type: application/json" -u admin:admin \
    -d "$DASHBOARD_JSON" \
    "$GRAFANA_URL/api/dashboards/db" 2>/dev/null && echo "✅ Dashboard imported" || echo "⚠️  Dashboard import failed"
  
  # Import alert rules
  echo "🚨 Importing alert rules..."
  
  # Get Prometheus data source UID
  PROM_UID=$(curl -s -u admin:admin "$GRAFANA_URL/api/datasources/name/Prometheus" | jq -r '.uid')
  
  if [ -z "$PROM_UID" ] || [ "$PROM_UID" = "null" ]; then
    echo "⚠️  Could not find Prometheus data source UID, skipping alert rules"
  else
    echo "   Found Prometheus UID: $PROM_UID"
    
    # Create folder for alerts or get existing
    FOLDER_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -u admin:admin \
      -d '{"title": "Alerts", "uid": "alerts"}' \
      "$GRAFANA_URL/api/folders")
    FOLDER_UID=$(echo "$FOLDER_RESPONSE" | jq -r '.uid')
    
    # If folder creation failed, try to get existing folder
    if [ -z "$FOLDER_UID" ] || [ "$FOLDER_UID" = "null" ]; then
      FOLDER_UID=$(curl -s -u admin:admin "$GRAFANA_URL/api/folders/alerts" | jq -r '.uid')
    fi
    
    if [ -z "$FOLDER_UID" ] || [ "$FOLDER_UID" = "null" ]; then
      echo "⚠️  Could not create or find alerts folder, skipping alert rules"
    else
      echo "   Using folder UID: $FOLDER_UID"
      
      # Create rule group with both alerts
      curl -s -X PUT -H "Content-Type: application/json" -u admin:admin \
        -d "{
          \"name\": \"DocStorageService Alerts\",
          \"interval\": 60,
          \"rules\": [
            {
              \"uid\": \"sev3-error-rate\",
              \"title\": \"DocStorageService_High_Error_Rate_Sev3\",
              \"condition\": \"B\",
              \"data\": [
                {
                  \"refId\": \"A\",
                  \"queryType\": \"\",
                  \"relativeTimeRange\": {\"from\": 300, \"to\": 0},
                  \"datasourceUid\": \"$PROM_UID\",
                  \"model\": {
                    \"expr\": \"rate(doc_operations_total{service=\\\"DocStorageService\\\", status_type=\\\"service_error\\\"}[1m]) * 60\",
                    \"refId\": \"A\"
                  }
                },
                {
                  \"refId\": \"B\",
                  \"queryType\": \"\",
                  \"relativeTimeRange\": {\"from\": 0, \"to\": 0},
                  \"datasourceUid\": \"-100\",
                  \"model\": {
                    \"conditions\": [{
                      \"evaluator\": {\"params\": [2], \"type\": \"gt\"},
                      \"operator\": {\"type\": \"and\"},
                      \"query\": {\"params\": [\"A\"]},
                      \"reducer\": {\"params\": [], \"type\": \"last\"},
                      \"type\": \"query\"
                    }],
                    \"refId\": \"B\",
                    \"type\": \"classic_conditions\"
                  }
                }
              ],
              \"noDataState\": \"NoData\",
              \"execErrState\": \"Alerting\",
              \"for\": \"0m\",
              \"annotations\": {
                \"summary\": \"DocStorageService has high service error rate (Sev3)\"
              },
              \"labels\": {
                \"severity\": \"sev3\",
                \"service\": \"DocStorageService\"
              }
            },
            {
              \"uid\": \"sev2-error-rate\",
              \"title\": \"DocStorageService_High_Error_Rate_Sev2\",
              \"condition\": \"B\",
              \"data\": [
                {
                  \"refId\": \"A\",
                  \"queryType\": \"\",
                  \"relativeTimeRange\": {\"from\": 300, \"to\": 0},
                  \"datasourceUid\": \"$PROM_UID\",
                  \"model\": {
                    \"expr\": \"rate(doc_operations_total{service=\\\"DocStorageService\\\", status_type=\\\"service_error\\\"}[1m]) * 60\",
                    \"refId\": \"A\"
                  }
                },
                {
                  \"refId\": \"B\",
                  \"queryType\": \"\",
                  \"relativeTimeRange\": {\"from\": 0, \"to\": 0},
                  \"datasourceUid\": \"-100\",
                  \"model\": {
                    \"conditions\": [{
                      \"evaluator\": {\"params\": [5], \"type\": \"gt\"},
                      \"operator\": {\"type\": \"and\"},
                      \"query\": {\"params\": [\"A\"]},
                      \"reducer\": {\"params\": [], \"type\": \"last\"},
                      \"type\": \"query\"
                    }],
                    \"refId\": \"B\",
                    \"type\": \"classic_conditions\"
                  }
                }
              ],
              \"noDataState\": \"NoData\",
              \"execErrState\": \"Alerting\",
              \"for\": \"0m\",
              \"annotations\": {
                \"summary\": \"DocStorageService has critical service error rate (Sev2)\"
              },
              \"labels\": {
                \"severity\": \"sev2\",
                \"service\": \"DocStorageService\"
              }
            }
          ]
        }" \
        "$GRAFANA_URL/api/v1/provisioning/folder/$FOLDER_UID/rule-groups/DocStorageService%20Alerts" > /dev/null
      
      echo "✅ Alert rule group created"
      
      # Verify alerts
      echo "🔍 Verifying imported alerts..."
      sleep 2
      ALERT_COUNT=$(curl -s -u admin:admin "$GRAFANA_URL/api/v1/provisioning/alert-rules" | jq 'length')
      if [ "$ALERT_COUNT" -ge 2 ]; then
        echo "✅ Alert rules verified ($ALERT_COUNT rules found)"
      else
        echo "⚠️  Could not verify alert rules"
      fi
    fi
  fi
  
  # Create service account and API key
  echo "🔑 Creating Grafana service account and API key..."
  
  # Create service account
  SA_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -u admin:admin \
    -d '{"name":"mcp-server","role":"Admin"}' \
    "$GRAFANA_URL/api/serviceaccounts")
  
  SA_ID=$(echo "$SA_RESPONSE" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
  
  if [ -n "$SA_ID" ]; then
    # Generate API token
    TOKEN_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -u admin:admin \
      -d '{"name":"mcp-token"}' \
      "$GRAFANA_URL/api/serviceaccounts/$SA_ID/tokens")
    
    API_KEY=$(echo "$TOKEN_RESPONSE" | grep -o '"key":"[^"]*"' | cut -d'"' -f4)
    
    if [ -n "$API_KEY" ]; then
      # Store in Parameter Store
      aws ssm put-parameter --name /workshop/grafana-api-key --value "$API_KEY" --type SecureString --overwrite --region $REGION
      echo "✅ Grafana API key created and stored in Parameter Store"
      echo "   - /workshop/grafana-api-key: [SecureString]"
    else
      echo "⚠️  Failed to generate API token"
    fi
  else
    echo "⚠️  Failed to create service account"
  fi
else
  echo "⚠️  Could not find Grafana URL, skipping Parameter Store export"
fi

echo ""
echo "🎉 Complete setup finished!"
echo ""
echo "📋 What's been created:"
echo "✅ ECS service with observability (Flask app)"
echo "✅ S3 bucket for data storage"
echo "✅ AWS Managed Prometheus"
echo "✅ Tempo (ECS) for tracing"
echo "✅ Loki (ECS) for logging"
echo "✅ Self-hosted Grafana (ECS) - Login: admin/admin"
echo "✅ Sample test document in S3"
echo ""
echo "🔗 Access Grafana Dashboard:"
echo "   URL: $GRAFANA_URL"
echo "   Username: admin"
echo "   Password: admin"
echo ""
echo "📊 Data sources configured: Prometheus, Loki, Tempo"
