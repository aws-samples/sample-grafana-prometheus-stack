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
