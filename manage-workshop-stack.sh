#!/bin/bash
set -e

case $STACK_OPERATION in
  create|update)
    echo "🎓 Deploying Workshop Environment..."
    
    # Install Node.js 22 LTS
    curl -sL https://rpm.nodesource.com/setup_22.x | sudo bash -
    sudo yum install -y nodejs jq git
    
    # Install AWS CDK
    sudo npm install -g aws-cdk
    
    # Run complete setup script (includes Parameter Store export)
    ./scripts/complete-setup.sh
    
    echo "✅ Workshop environment fully deployed!"
    ;;
    
  delete)
    echo "🧹 Cleaning up workshop..."
    cdk destroy --force || true
    
    # Clean up Parameter Store
    aws ssm delete-parameter --name /workshop/grafana-url --region ${AWS_REGION:-us-west-2} || true
    aws ssm delete-parameter --name /workshop/grafana-api-key --region ${AWS_REGION:-us-west-2} || true
    ;;
    
  *)
    echo "Unknown operation: $STACK_OPERATION"
    exit 1
    ;;
esac
