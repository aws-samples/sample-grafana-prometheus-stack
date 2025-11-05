#!/bin/bash

echo "🔧 Setting up AWS Managed Grafana..."

# Ensure region is set
REGION=${AWS_DEFAULT_REGION:-$(aws configure get region)}
if [ -z "$REGION" ]; then
    REGION="us-west-2"
    echo "⚠️  No region configured, defaulting to us-west-2"
fi

export AWS_DEFAULT_REGION=$REGION
echo "📍 Using region: $REGION"

# Check if SSO is enabled
echo "📋 Checking AWS SSO status..."
SSO_INSTANCES=$(aws sso-admin list-instances --region $REGION --query 'Instances[0].InstanceArn' --output text 2>/dev/null)

if [ "$SSO_INSTANCES" = "None" ] || [ -z "$SSO_INSTANCES" ]; then
    echo "❌ AWS SSO is not enabled in region $REGION"
    echo "📝 Enable SSO at: https://$REGION.console.aws.amazon.com/singlesignon/home?region=$REGION"
    exit 1
fi

echo "✅ AWS SSO is enabled: $SSO_INSTANCES"

# Create Grafana service role
echo "🔑 Creating Grafana service role..."
ROLE_NAME="GrafanaWorkspaceRole"

# Check if role exists
EXISTING_ROLE=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text 2>/dev/null)

if [ -n "$EXISTING_ROLE" ] && [ "$EXISTING_ROLE" != "None" ]; then
    echo "✅ Using existing role: $EXISTING_ROLE"
    ROLE_ARN=$EXISTING_ROLE
else
    echo "🔨 Creating new IAM role..."
    
    # Create trust policy
    cat > /tmp/grafana-trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "grafana.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

    # Create role
    ROLE_ARN=$(aws iam create-role \
        --role-name $ROLE_NAME \
        --assume-role-policy-document file:///tmp/grafana-trust-policy.json \
        --query 'Role.Arn' \
        --output text)
    
    # Attach managed policy
    aws iam attach-role-policy \
        --role-name $ROLE_NAME \
        --policy-arn arn:aws:iam::aws:policy/AmazonPrometheusQueryAccess
    
    # Add workspace-specific permissions
    cat > /tmp/prometheus-workspace-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "aps:QueryMetrics",
                "aps:GetSeries",
                "aps:GetLabels",
                "aps:GetMetricMetadata"
            ],
            "Resource": "arn:aws:aps:${REGION}:*:workspace/*"
        }
    ]
}
EOF
    
    # Create and attach workspace-specific policy
    POLICY_ARN=$(aws iam create-policy \
        --policy-name GrafanaPrometheusWorkspaceAccess \
        --policy-document file:///tmp/prometheus-workspace-policy.json \
        --query 'Policy.Arn' \
        --output text 2>/dev/null || \
        aws iam list-policies \
        --query 'Policies[?PolicyName==`GrafanaPrometheusWorkspaceAccess`].Arn' \
        --output text)
    
    aws iam attach-role-policy \
        --role-name $ROLE_NAME \
        --policy-arn $POLICY_ARN
    
    rm /tmp/prometheus-workspace-policy.json
    
    echo "✅ Created role: $ROLE_ARN"
    rm /tmp/grafana-trust-policy.json
fi

# Get Prometheus workspace ID
echo "📊 Getting Prometheus workspace ID..."
PROMETHEUS_WORKSPACE_ID=$(aws cloudformation describe-stacks \
  --region $REGION \
  --stack-name GrafanaObservabilityStackStack \
  --query 'Stacks[0].Outputs[?OutputKey==`PrometheusWorkspaceId`].OutputValue' \
  --output text)

if [ -z "$PROMETHEUS_WORKSPACE_ID" ] || [ "$PROMETHEUS_WORKSPACE_ID" = "None" ]; then
    echo "❌ Could not find Prometheus workspace ID. Make sure the stack is deployed."
    exit 1
fi

echo "📊 Found Prometheus workspace: $PROMETHEUS_WORKSPACE_ID"

# Ensure Grafana role has access to the specific workspace
echo "🔐 Updating Grafana role permissions for workspace access..."
cat > /tmp/workspace-specific-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "aps:QueryMetrics",
                "aps:GetSeries", 
                "aps:GetLabels",
                "aps:GetMetricMetadata"
            ],
            "Resource": "arn:aws:aps:${REGION}:*:workspace/${PROMETHEUS_WORKSPACE_ID}"
        }
    ]
}
EOF

# Update existing role with workspace-specific permissions
WORKSPACE_POLICY_ARN=$(aws iam create-policy \
    --policy-name GrafanaSpecificWorkspaceAccess-${PROMETHEUS_WORKSPACE_ID} \
    --policy-document file:///tmp/workspace-specific-policy.json \
    --query 'Policy.Arn' \
    --output text 2>/dev/null || \
    aws iam list-policies \
    --query "Policies[?PolicyName=='GrafanaSpecificWorkspaceAccess-${PROMETHEUS_WORKSPACE_ID}'].Arn" \
    --output text)

aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn $WORKSPACE_POLICY_ARN 2>/dev/null || true

# Add additional Prometheus and CloudWatch permissions
cat > /tmp/additional-prometheus-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "aps:DescribeWorkspace",
                "aps:ListWorkspaces"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "sns:Publish"
            ],
            "Resource": "arn:aws:sns:${REGION}:*:grafana-*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "cloudwatch:GetMetricStatistics",
                "cloudwatch:ListMetrics",
                "cloudwatch:GetMetricData",
                "cloudwatch:DescribeAlarms",
                "logs:DescribeLogGroups",
                "logs:DescribeLogStreams",
                "logs:GetLogEvents",
                "logs:StartQuery",
                "logs:StopQuery",
                "logs:GetQueryResults",
                "ec2:DescribeRegions",
                "ec2:DescribeInstances",
                "ecs:ListClusters",
                "ecs:ListServices",
                "ecs:DescribeServices",
                "ecs:ListTasks",
                "ecs:DescribeTasks"
            ],
            "Resource": "*"
        }
    ]
}
EOF

aws iam put-role-policy \
    --role-name $ROLE_NAME \
    --policy-name AdditionalPrometheusAccess \
    --policy-document file:///tmp/additional-prometheus-policy.json 2>/dev/null || true

rm /tmp/workspace-specific-policy.json /tmp/additional-prometheus-policy.json
echo "✅ Updated Grafana role permissions"

# Check if Grafana workspace already exists
echo "🔍 Checking for existing Grafana workspace..."
EXISTING_WORKSPACE=$(aws grafana list-workspaces \
  --region $REGION \
  --query 'workspaces[?name==`grafana-observability-workspace`].[id,status,endpoint]' \
  --output text)

if [ -n "$EXISTING_WORKSPACE" ]; then
    WORKSPACE_ID=$(echo "$EXISTING_WORKSPACE" | awk '{print $1}')
    WORKSPACE_STATUS=$(echo "$EXISTING_WORKSPACE" | awk '{print $2}')
    WORKSPACE_URL=$(echo "$EXISTING_WORKSPACE" | awk '{print $3}')
    
    echo "✅ Found existing workspace: $WORKSPACE_ID (Status: $WORKSPACE_STATUS)"
    
    if [ "$WORKSPACE_STATUS" = "ACTIVE" ]; then
        echo "🎉 Workspace is ready!"
        echo "🌐 Grafana URL: $WORKSPACE_URL"
        echo ""
        
        # Check if unified alerting is already enabled
        echo "🔍 Checking unified alerting status..."
        ALERTING_STATUS=$(aws grafana describe-workspace-configuration \
          --workspace-id $WORKSPACE_ID \
          --region $REGION \
          --query 'configuration.unifiedAlerting.enabled' \
          --output text 2>/dev/null)

        if [ "$ALERTING_STATUS" = "true" ]; then
            echo "✅ Unified alerting is already enabled"
        else
            echo "🚨 Enabling unified alerting..."
            ALERTING_RESULT=$(aws grafana update-workspace-configuration \
              --workspace-id $WORKSPACE_ID \
              --configuration '{"unifiedAlerting":{"enabled":true}}' \
              --region $REGION 2>&1)
            
            if [ $? -eq 0 ]; then
                echo "✅ Unified alerting enabled successfully"
            else
                echo "⚠️  Failed to enable unified alerting: $ALERTING_RESULT"
                echo "   You may need to enable it manually in the Grafana console"
            fi
        fi
        echo ""
        
        # First: Add users to Grafana
        echo "👤 Setting up Grafana users..."
        ./add-grafana-user.sh
        
        echo ""
        echo "🔧 Configuring data sources and dashboards..."
        ./grafana/configure-grafana.sh
        exit 0
    else
        echo "⏳ Workspace exists but not ready yet. Waiting for ACTIVE status..."
    fi
else
    echo "📝 No existing workspace found. Creating new one..."
    
    # Create Grafana workspace
    echo "🔨 Creating Grafana workspace..."
    GRAFANA_RESULT=$(aws grafana create-workspace \
      --region $REGION \
      --account-access-type CURRENT_ACCOUNT \
      --authentication-providers AWS_SSO \
      --permission-type SERVICE_MANAGED \
      --workspace-data-sources PROMETHEUS \
      --workspace-name grafana-observability-workspace \
      --workspace-role-arn ${ROLE_ARN}\
      --output json 2>&1)


    if [ $? -ne 0 ]; then
        echo "❌ Failed to create Grafana workspace"
        echo "Error: $GRAFANA_RESULT"
        exit 1
    fi
    
    WORKSPACE_ID=$(echo "$GRAFANA_RESULT" | jq -r '.workspace.id // empty')
    WORKSPACE_URL=$(echo "$GRAFANA_RESULT" | jq -r '.workspace.endpoint // empty')
    
    echo "✅ Grafana workspace creation initiated!"
    echo "🆔 Workspace ID: $WORKSPACE_ID"
fi

# Wait for workspace to be ACTIVE
echo "⏳ Waiting for workspace to become ACTIVE..."
TIMEOUT=600  # 10 minutes timeout
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    CURRENT_STATUS=$(aws grafana describe-workspace \
      --region $REGION \
      --workspace-id $WORKSPACE_ID \
      --query 'workspace.status' \
      --output text)
    
    echo "📊 Current status: $CURRENT_STATUS (${ELAPSED}s elapsed)"
    
    if [ "$CURRENT_STATUS" = "ACTIVE" ]; then
        echo "🎉 Workspace is now ACTIVE!"
        
        # Get the final endpoint URL
        WORKSPACE_URL=$(aws grafana describe-workspace \
          --region $REGION \
          --workspace-id $WORKSPACE_ID \
          --query 'workspace.endpoint' \
          --output text)
        
        echo "🌐 Grafana URL: $WORKSPACE_URL"
        echo ""
        
        # Check if unified alerting is already enabled
        echo "🔍 Checking unified alerting status..."
        ALERTING_STATUS=$(aws grafana describe-workspace-configuration \
          --workspace-id $WORKSPACE_ID \
          --region $REGION \
          --query 'configuration.unifiedAlerting.enabled' \
          --output text 2>/dev/null)

        if [ "$ALERTING_STATUS" = "true" ]; then
            echo "✅ Unified alerting is already enabled"
        else
            echo "🚨 Enabling unified alerting..."
            ALERTING_RESULT=$(aws grafana update-workspace-configuration \
              --workspace-id $WORKSPACE_ID \
              --configuration '{"unifiedAlerting":{"enabled":true}}' \
              --region $REGION 2>&1)
            
            if [ $? -eq 0 ]; then
                echo "✅ Unified alerting enabled successfully"
            else
                echo "⚠️  Failed to enable unified alerting: $ALERTING_RESULT"
                echo "   You may need to enable it manually in the Grafana console"
            fi
        fi
        echo ""
        
        # First: Add users to Grafana
        echo "👤 Setting up Grafana users..."
        ./add-grafana-user.sh
        
        echo ""
        echo "🔧 Configuring data sources and dashboards..."
        ./grafana/configure-grafana.sh
        
        echo ""
        echo "🎉 Complete setup finished!"
        echo "📊 Access Grafana: $WORKSPACE_URL"
        echo "🧪 Run './test-api.sh' to generate sample data"
        exit 0
    elif [ "$CURRENT_STATUS" = "CREATION_FAILED" ]; then
        echo "❌ Workspace creation failed!"
        exit 1
    fi
    
    sleep 30
    ELAPSED=$((ELAPSED + 30))
done

echo "⏰ Timeout waiting for workspace to become active"
echo "📊 Check workspace status manually: aws grafana describe-workspace --workspace-id $WORKSPACE_ID"
exit 1
