#!/bin/bash
set -e

REGION="us-west-2"
STACK_NAME="GrafanaObservabilityStackStack"

echo "=== ECS Task Role Diagnostics ==="
echo ""

# Get cluster and service names
CLUSTER=$(aws cloudformation describe-stack-resources \
  --stack-name $STACK_NAME \
  --region $REGION \
  --query "StackResources[?ResourceType=='AWS::ECS::Cluster'].PhysicalResourceId" \
  --output text)

GRAFANA_SERVICE=$(aws cloudformation describe-stack-resources \
  --stack-name $STACK_NAME \
  --region $REGION \
  --query "StackResources[?LogicalResourceId=='GrafanaService'].PhysicalResourceId" \
  --output text)

echo "Cluster: $CLUSTER"
echo "Service: $GRAFANA_SERVICE"
echo ""

# Get running task
TASK_ARN=$(aws ecs list-tasks \
  --cluster $CLUSTER \
  --service-name $GRAFANA_SERVICE \
  --region $REGION \
  --query 'taskArns[0]' \
  --output text)

echo "Task ARN: $TASK_ARN"
echo ""

# Get task definition from running task
TASK_DEF=$(aws ecs describe-tasks \
  --cluster $CLUSTER \
  --tasks $TASK_ARN \
  --region $REGION \
  --query 'tasks[0].taskDefinitionArn' \
  --output text)

echo "=== Task Definition Roles ==="
aws ecs describe-task-definition \
  --task-definition $TASK_DEF \
  --region $REGION \
  --query 'taskDefinition.{taskRole:taskRoleArn,executionRole:executionRoleArn}' \
  --output json

echo ""
echo "=== Running Task Roles ==="
aws ecs describe-tasks \
  --cluster $CLUSTER \
  --tasks $TASK_ARN \
  --region $REGION \
  --query 'tasks[0].{taskRole:taskRoleArn,executionRole:executionRoleArn,overrides:overrides}' \
  --output json

echo ""
echo "=== Recent Grafana Logs (last 20 lines) ==="
aws logs tail /ecs/grafana \
  --region $REGION \
  --since 5m \
  --format short \
  | tail -20
