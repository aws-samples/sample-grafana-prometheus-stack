# ECS Fargate Task Role Attachment Failure

## Problem

ECS Fargate platform 1.4.0 fails to attach IAM roles to running tasks despite correct task definition configuration. Grafana container cannot authenticate to AWS Managed Prometheus, resulting in continuous 403 errors.

## Observations

Task definition revision 49 specifies both roles:
```
taskRoleArn: arn:aws:iam::206524433062:role/GrafanaObservabilityStack-GrafanaTaskTaskRole195A15-Uz06JZouZYYs
executionRoleArn: arn:aws:iam::206524433062:role/GrafanaObservabilityStack-GrafanaTaskExecutionRole0-rRhcrE5s0NDD
```

Running task `43ae5beb75194f25b607f22f2d51f432` on cluster `GrafanaObservabilityCluster40F7049E-tGFh0wYEQGb6`:
```
taskRoleArn: <field not present>
executionRoleArn: <field not present>
```

IAM role exists with correct trust policy (`ecs-tasks.amazonaws.com`) and permissions. CloudTrail shows zero AssumeRole attempts. `RoleLastUsed` is empty.

CDK code originally used implicit role creation via `addToTaskRolePolicy()`. Changed to explicit role creation matching Tempo/Loki pattern:

```typescript
const grafanaTaskRole = new iam.Role(this, 'GrafanaTaskRole', {
  assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
});

const grafanaTaskDefinition = new ecs.FargateTaskDefinition(this, 'GrafanaTask', {
  taskRole: grafanaTaskRole,
  // ...
});
```

Redeployed as revision 50 to new cluster `GrafanaObservabilityStackStack-ObservabilityCluster40F7049E-T3ELdZCnQ9Wb`. Running task `04ab5455f5034027925614f486b4fc28` still missing both role fields.

Container logs from 2025-11-20 22:01 UTC:
```
status=403 body="{\"message\":\"Missing Authentication Token\"}"
```

Verified via ECS MCP `DescribeTasks` and AWS CLI. Both confirm role fields absent from running task API response.

## Conclusion

ECS Fargate 1.4.0 platform bug. Task definition correctly configured, IAM roles exist with proper permissions, but ECS runtime fails to attach roles to containers. Issue persists across multiple revisions, clusters, and CDK implementation patterns.
