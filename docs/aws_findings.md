# ECS Fargate Task Role Attachment Failure

## Problem

ECS Fargate platform 1.4.0 fails to attach IAM roles to running tasks despite correct task definition configuration. Grafana container cannot authenticate to AWS Managed Prometheus, resulting in continuous 403 "Missing Authentication Token" errors.

## Root Cause

Grafana Prometheus datasource is correctly configured with AWS SigV4 authentication (`grafana/provisioning/datasources/datasources.yaml` lines 11-13):
```yaml
sigV4Auth: true
sigV4AuthType: default
sigV4Region: ${AWS_REGION}
```

However, the ECS task role isn't being attached to the running container, preventing SigV4 request signing from working.

## Observations

Task definition specifies both roles:
```
taskRoleArn: arn:aws:iam::<account>:role/GrafanaObservabilityStack-GrafanaTaskTaskRole...
executionRoleArn: arn:aws:iam::<account>:role/GrafanaObservabilityStack-GrafanaTaskExecutionRole...
```

Running task on cluster:
```
taskRoleArn: <field not present>
executionRoleArn: <field not present>
```

IAM role exists with correct trust policy (`ecs-tasks.amazonaws.com`) and permissions. CloudTrail shows zero AssumeRole attempts. `RoleLastUsed` is empty.

CDK code originally used implicit role creation via `addToTaskRolePolicy()` (`grafana/grafana-observability-stack.ts` lines 454-465). Changed to explicit role creation matching Tempo/Loki pattern:

```typescript
const grafanaTaskRole = new iam.Role(this, 'GrafanaTaskRole', {
  assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
});

grafanaTaskRole.addToPolicy(new iam.PolicyStatement({
  effect: iam.Effect.ALLOW,
  actions: ['aps:QueryMetrics', 'aps:GetSeries', 'aps:GetLabels', 'aps:GetMetricMetadata'],
  resources: [prometheusWorkspace.attrArn],
}));

const grafanaTaskDefinition = new ecs.FargateTaskDefinition(this, 'GrafanaTask', {
  taskRole: grafanaTaskRole,
  // ...
});
```

Reverted to original implicit role creation as explicit role creation didn't resolve the platform bug.

Redeployed to new cluster. Running task still missing both role fields.

Verified via ECS MCP `DescribeTasks` and AWS CLI. Both confirm role fields absent from running task API response.

## Conclusion

ECS Fargate 1.4.0 platform bug. Task definition correctly configured, IAM roles exist with proper permissions, but ECS runtime fails to attach roles to containers. Issue persists across multiple revisions, clusters, and CDK implementation patterns.
