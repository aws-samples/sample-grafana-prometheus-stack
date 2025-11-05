#!/bin/bash

echo "🚀 Complete Grafana Observability Stack Setup"
echo "============================================="

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

# Step 1.5: Create sample document in S3 for testing
echo ""
echo "📄 Step 1.5: Creating sample document for testing..."
BUCKET_NAME=$(aws cloudformation describe-stacks --stack-name GrafanaObservabilityStackStack --region $REGION --query 'Stacks[0].Outputs[?OutputKey==`S3BucketName`].OutputValue' --output text 2>/dev/null)

if [ -n "$BUCKET_NAME" ] && [ "$BUCKET_NAME" != "None" ]; then
    echo '{"test": "sample-data", "created": "'$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)'"}' | aws s3 cp - s3://$BUCKET_NAME/documents/test-document.json
    echo "✅ Sample document created at s3://$BUCKET_NAME/documents/test-document.json"
else
    echo "⚠️  Could not find S3 bucket name, sample document creation skipped"
fi

# Step 2: Check if Grafana setup was completed by deploy.sh
echo ""
echo "🔍 Step 2: Verifying Grafana workspace status..."
WORKSPACE_ID=$(aws grafana list-workspaces --region $REGION --query 'workspaces[?name==`grafana-observability-workspace`].id' --output text 2>/dev/null)

if [ -z "$WORKSPACE_ID" ] || [ "$WORKSPACE_ID" = "None" ]; then
    echo "⚠️  Grafana workspace not found. Checking SSO status..."
    SSO_INSTANCES=$(aws sso-admin list-instances --region $REGION --query 'Instances[0].InstanceArn' --output text 2>/dev/null)
    
    if [ "$SSO_INSTANCES" = "None" ] || [ -z "$SSO_INSTANCES" ]; then
        echo "⚠️  AWS SSO needs to be enabled manually"
        echo ""
        echo "⏸️  Setup paused. After enabling SSO, run:"
        echo "   ./grafana/setup-grafana.sh"
        echo "   ./tests/test.sh"
        exit 0
    else
        echo "📊 Setting up Grafana workspace..."
        ./grafana/setup-grafana.sh
    fi
else
    echo "✅ Grafana workspace found, updating permissions only..."
    ./grafana/setup-grafana.sh
fi

# Step 3: Test API
echo ""
echo "🧪 Step 3: Testing API endpoints..."
./tests/test.sh

echo ""
echo "🎉 Complete setup finished!"
echo ""
echo "📋 What's been created:"
echo "✅ ECS service with observability (Flask app)"
echo "✅ API Gateway with REST endpoints"
echo "✅ S3 bucket for data storage"
echo "✅ AWS Managed Prometheus"
echo "✅ Tempo (ECS) for tracing"
echo "✅ Loki (ECS) for logging"
echo "✅ AWS Managed Grafana workspace"
echo "✅ Sample test document in S3"
echo ""
echo "🔗 New endpoints:"
echo "   Data Processor: Check CloudFormation outputs"
echo "   Metrics:        http://<alb-dns>:9090/metrics"
echo ""
echo "📊 Access your Grafana dashboard and import the sample dashboards from dashboards/"
