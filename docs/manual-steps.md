# Manual Steps After Deployment

This document outlines any manual steps required after running `scripts/complete-setup.sh`.

## Prerequisites Before Running Setup

### 1. AWS SSO Configuration
If AWS SSO is not enabled in your account, you'll need to enable it manually:

1. Go to AWS Console → AWS SSO
2. Click "Enable AWS SSO"
3. Choose your identity source (AWS SSO identity store or external provider)
4. Complete the setup wizard

**Note**: The setup script will detect if SSO is missing and pause with instructions.

### 2. Required AWS Permissions
Ensure your AWS credentials have the following permissions:
- CloudFormation full access
- ECS full access
- EC2 full access (for VPC, ALB, Security Groups)
- IAM role creation and management
- S3 bucket creation and management
- AWS Managed Prometheus workspace creation
- AWS Managed Grafana workspace creation
- Lambda function creation and management
- EventBridge rule creation

## Post-Deployment Manual Steps

### 1. Access Grafana Dashboard

After successful deployment:

1. **Get Grafana URL**:
   ```bash
   aws grafana list-workspaces --region us-east-1 --query 'workspaces[0].endpoint' --output text
   ```

2. **Login to Grafana**:
   - Click the Grafana URL from step 1
   - Use AWS SSO to authenticate
   - You should see the Grafana dashboard with pre-configured data sources

### 2. Import Sample Dashboards

1. In Grafana, go to **Dashboards** → **Import**
2. Upload the dashboard JSON files from the `dashboards/` directory:
   - `application-metrics-dashboard.json`
   - `infrastructure-overview-dashboard.json`
   - `distributed-tracing-dashboard.json`

### 3. Verify Data Sources

Check that all data sources are working:

1. Go to **Configuration** → **Data Sources**
2. Verify these are configured and working:
   - **AWS Managed Prometheus** (should show green checkmark)
   - **Loki** (should show green checkmark)
   - **Tempo** (should show green checkmark)

### 4. Generate Test Data

Run the test script to generate sample observability data:
```bash
./tests/test.sh
```

This will create metrics, traces, and logs that you can view in Grafana.

## Troubleshooting Common Issues

### Issue: Grafana Data Sources Not Working

**Symptoms**: Data sources show red X or "Data source not found"

**Solutions**:
1. Check ECS services are running:
   ```bash
   aws ecs list-services --cluster grafana-observability-cluster --region us-east-1
   ```

2. Verify load balancer endpoints:
   ```bash
   aws cloudformation describe-stacks --stack-name GrafanaObservabilityStackStack --region us-east-1 --query 'Stacks[0].Outputs'
   ```

3. Re-run data source configuration:
   ```bash
   ./grafana/configure-grafana.sh
   ```

### Issue: No Metrics in Prometheus

**Symptoms**: Prometheus data source connected but no metrics visible

**Solutions**:
1. Check Prometheus scraper logs:
   ```bash
   aws logs get-log-events --log-group-name /ecs/prometheus-scraper --region us-east-1
   ```

2. Verify metrics endpoint is accessible:
   ```bash
   # Get ALB DNS from CloudFormation outputs
   curl http://<data-processor-alb-dns>:9090/metrics
   ```

### Issue: ECS Services Not Starting

**Symptoms**: ECS services stuck in "PENDING" state

**Solutions**:
1. Check ECS service events:
   ```bash
   aws ecs describe-services --cluster grafana-observability-cluster --services data-processor-service --region us-east-1
   ```

2. Check CloudWatch logs for container errors:
   ```bash
   aws logs describe-log-groups --log-group-name-prefix /ecs/ --region us-east-1
   ```

## Getting Service URLs

After deployment, get important URLs:

```bash
# Get all stack outputs
aws cloudformation describe-stacks --stack-name GrafanaObservabilityStackStack --region us-east-1 --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table

# Get Grafana workspace URL
aws grafana list-workspaces --region us-east-1 --query 'workspaces[0].endpoint' --output text
```

## Clean Up

To remove all resources:
```bash
cdk destroy
```

**Note**: This will delete all data including metrics, traces, and logs stored in the observability stack.
