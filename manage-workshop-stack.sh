#!/bin/bash

STACK_OPERATION=$1

if [[ "$STACK_OPERATION" == "Create" || "$STACK_OPERATION" == "Update" ]]; then
    echo "🎓 Deploying Workshop Environment..."
    
    # Run complete setup script (includes Parameter Store export)
    ./scripts/complete-setup.sh
    
    echo "✅ Workshop environment fully deployed!"
   
elif [ "$STACK_OPERATION" == "Delete" ]; then
    echo "🧹 Cleaning up workshop..."
    cdk destroy --force || true
    
    # Clean up Parameter Store
    aws ssm delete-parameter --name /workshop/grafana-url --region ${AWS_REGION:-us-west-2} || true
    aws ssm delete-parameter --name /workshop/grafana-api-key --region ${AWS_REGION:-us-west-2} || true
  
else
    echo "Invalid stack operation!"
    exit 1
fi