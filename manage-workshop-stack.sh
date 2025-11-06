#!/bin/bash
set -e

case $STACK_OPERATION in
  create)
    echo "🎓 Creating Workshop Environment..."
    
    # Install Node.js 22 LTS
    curl -sL https://rpm.nodesource.com/setup_22.x | sudo bash -
    sudo yum install -y nodejs jq git
    
    # Install AWS CDK
    sudo npm install -g aws-cdk
    
    # Clone and setup
    cd /home/ec2-user/environment
    git clone https://github.com/aws-samples/sample-grafana-prometheus-stack.git grafana-workshop
    cd grafana-workshop
    
    # Run complete setup script
    ./scripts/complete-setup.sh
    
    echo "✅ Workshop environment fully deployed!"
    
    # Export Grafana details to Parameter Store for downstream workshops
    echo "📝 Exporting Grafana configuration to Parameter Store..."
    
    GRAFANA_WORKSPACE_ID=$(aws grafana list-workspaces --region ${AWS_REGION:-us-west-2} --query 'workspaces[0].id' --output text)
    GRAFANA_URL="https://${GRAFANA_WORKSPACE_ID}.grafana-workspace.${AWS_REGION:-us-west-2}.amazonaws.com"
    
    # Create Grafana API key using AWS Grafana API
    GRAFANA_API_KEY=$(aws grafana create-workspace-api-key \
      --key-name "workshop-mcp-server-$(date +%s)" \
      --key-role ADMIN \
      --seconds-to-live 86400 \
      --workspace-id "$GRAFANA_WORKSPACE_ID" \
      --region ${AWS_REGION:-us-west-2} \
      --query 'key' --output text)
    
    # Store in Parameter Store
    aws ssm put-parameter --name /workshop/grafana-url --value "$GRAFANA_URL" --type String --overwrite --region ${AWS_REGION:-us-west-2}
    aws ssm put-parameter --name /workshop/grafana-api-key --value "$GRAFANA_API_KEY" --type SecureString --overwrite --region ${AWS_REGION:-us-west-2}
    
    echo "✅ Grafana configuration exported to Parameter Store"
    ;;
    
  delete)
    echo "🧹 Cleaning up workshop..."
    cd /home/ec2-user/environment/grafana-workshop
    cdk destroy --force || true
    ;;
    
  *)
    echo "Unknown operation: $STACK_OPERATION"
    exit 1
    ;;
esac
