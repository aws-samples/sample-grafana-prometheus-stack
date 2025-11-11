#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import {DeploymentStrategy} from 'aws-cdk-lib/aws-ecs';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as efs from 'aws-cdk-lib/aws-efs';
import {LifecyclePolicy} from 'aws-cdk-lib/aws-efs';

import * as logs from 'aws-cdk-lib/aws-logs';
import * as aps from 'aws-cdk-lib/aws-aps';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as snsSubscriptions from 'aws-cdk-lib/aws-sns-subscriptions';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import {Construct} from 'constructs';

export class GrafanaObservabilityStackStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // S3 Bucket for data storage
    const dataBucket = new s3.Bucket(this, 'DataBucket', {
      bucketName: `grafana-observability-data-${this.account}-${this.region}`,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // VPC for ECS services
    const vpc = new ec2.Vpc(this, 'ObservabilityVPC', {
      maxAzs: 2,
      natGateways: 1,
      enableDnsHostnames: true,
      enableDnsSupport: true,
    });

    // ECS Cluster for Tempo and Loki
    const cluster = new ecs.Cluster(this, 'ObservabilityCluster', {
      vpc,
      containerInsights: false,
    });

    // Security group for ECS tasks
    const ecsSecurityGroup = new ec2.SecurityGroup(this, 'EcsSecurityGroup', {
      vpc,
      description: 'Security group for ECS tasks',
    });

    // Allow ECS tasks to access EFS
    ecsSecurityGroup.addIngressRule(
      ecsSecurityGroup,
      ec2.Port.tcp(2049),
      'Allow NFS access from ECS tasks'
    );

    // Allow ECS tasks outbound access
    ecsSecurityGroup.addEgressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.allTraffic(),
      'Allow all outbound traffic'
    );

    const observabilityFileSystem = new efs.FileSystem(this, 'ObservabilityEFS2', {
      vpc,
      enableAutomaticBackups: true,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      performanceMode: efs.PerformanceMode.GENERAL_PURPOSE,
      throughputMode: efs.ThroughputMode.ELASTIC,
      securityGroup: ecsSecurityGroup,
      allowAnonymousAccess: true,
      transitionToArchivePolicy: LifecyclePolicy.AFTER_90_DAYS,
      vpcSubnets: {
          subnets: vpc.privateSubnets,
      }
    });

    // EFS Access Point for Loki
    const lokiAccessPoint = new efs.AccessPoint(this, 'LokiAccessPoint', {
      fileSystem: observabilityFileSystem,
      path: '/loki-storage',
      createAcl: {
        ownerUid: '0',
        ownerGid: '0',
        permissions: '0755',
      },
      posixUser: {
        uid: '0',
        gid: '0',
        secondaryGids: [],
      },
    });

    // EFS Access Point for Tempo
    const tempoAccessPoint = new efs.AccessPoint(this, 'TempoAccessPoint', {
      fileSystem: observabilityFileSystem,
      path: '/tempo-storage',
      createAcl: {
        ownerUid: '0',
        ownerGid: '0',
        permissions: '0755',
      },
      posixUser: {
        uid: '0',
        gid: '0',
        secondaryGids: [],
      },
    });

    // AWS Managed Prometheus
    const prometheusWorkspace = new aps.CfnWorkspace(this, 'PrometheusWorkspace', {
      alias: 'grafana-observability-prometheus',
    });

    // S3 bucket for Tempo traces
    const tempoBucket = new s3.Bucket(this, 'TempoBucket', {
      bucketName: `tempo-traces-${this.account}-${this.region}`,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // IAM role for Tempo to access S3
    const tempoTaskRole = new iam.Role(this, 'TempoTaskRole', {
      assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
      inlinePolicies: {
        S3Access: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ['s3:ListBucket'],
              resources: [tempoBucket.bucketArn],
            }),
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ['s3:GetObject', 's3:PutObject', 's3:DeleteObject'],
              resources: [`${tempoBucket.bucketArn}/*`],
            }),
          ],
        }),
      },
    });
    // Tempo (Tracing) - ECS Service with EFS persistent storage
    const tempoTaskDefinition = new ecs.FargateTaskDefinition(this, 'TempoTask', {
      memoryLimitMiB: 1024,
      cpu: 512,
      taskRole: tempoTaskRole,
    });

    // Add EFS volume for Tempo
    tempoTaskDefinition.addVolume({
      name: 'tempo-storage',
      efsVolumeConfiguration: {
        fileSystemId: observabilityFileSystem.fileSystemId,
        transitEncryption: 'ENABLED',
        authorizationConfig: {
          accessPointId: tempoAccessPoint.accessPointId,
          iam: 'ENABLED',
        },
        rootDirectory: '/',
      },
    });

    const tempoContainer = tempoTaskDefinition.addContainer('tempo', {
      image: ecs.ContainerImage.fromRegistry('grafana/tempo:2.3.0'),
      memoryLimitMiB: 512,
      portMappings: [
        { containerPort: 3200, protocol: ecs.Protocol.TCP }, // Tempo API
        { containerPort: 4317, protocol: ecs.Protocol.TCP }, // OTLP gRPC
        { containerPort: 4318, protocol: ecs.Protocol.TCP }, // OTLP HTTP
      ],
      logging: ecs.LogDrivers.awsLogs({
        streamPrefix: 'tempo',
        logGroup: new logs.LogGroup(this, 'TempoLogGroup', {
          logGroupName: '/ecs/tempo',
          removalPolicy: cdk.RemovalPolicy.DESTROY,
        }),
      }),
      entryPoint: ['/bin/sh', '-c'],
      command: [`
        mkdir -p /etc/tempo /mnt/tempo-data/traces && cat > /etc/tempo/tempo.yaml << 'EOF'
server:
  http_listen_port: 3200
distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
storage:
  trace:
    backend: s3
    s3:
      bucket: ${tempoBucket.bucketName}
      endpoint: s3.${this.region}.amazonaws.com
      region: ${this.region}
      access_key: ""
      secret_key: ""
      insecure: false
compactor:
  compaction:
    block_retention: 168h
EOF
        exec /tempo -config.file=/etc/tempo/tempo.yaml
      `],
    });

    // Mount EFS volume to Tempo container
    tempoContainer.addMountPoints({
      sourceVolume: 'tempo-storage',
      containerPath: '/mnt/tempo-data',
      readOnly: false,
    });

    // Add Application Load Balancer for Tempo
    const tempoLoadBalancer = new elbv2.ApplicationLoadBalancer(this, 'TempoLoadBalancer', {
      vpc,
      internetFacing: true,
    });

    // Create listeners first
    const tempoListener = tempoLoadBalancer.addListener('TempoListener', {
      port: 3200,
      protocol: elbv2.ApplicationProtocol.HTTP,
    });

    const tempoOtlpListener = tempoLoadBalancer.addListener('TempoOtlpListener', {
      port: 4318,
      protocol: elbv2.ApplicationProtocol.HTTP,
    });

    // Create ECS service
    const tempoService = new ecs.FargateService(this, 'TempoService', {
      cluster,
      taskDefinition: tempoTaskDefinition,
      desiredCount: 1,
      healthCheckGracePeriod: cdk.Duration.seconds(60),
      securityGroups: [ecsSecurityGroup],
      vpcSubnets: {
        subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
      },
      assignPublicIp: false,
    });

    // Add targets to listeners with correct container ports
    tempoListener.addTargets('TempoApiTargets', {
      port: 3200,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targets: [tempoService.loadBalancerTarget({
        containerName: 'tempo',
        containerPort: 3200,
      })],
      healthCheck: {
        path: '/status',
        interval: cdk.Duration.seconds(30),
        timeout: cdk.Duration.seconds(5),
        healthyThresholdCount: 2,
        unhealthyThresholdCount: 3,
      },
    });

    tempoOtlpListener.addTargets('TempoOtlpTargets', {
      port: 4318,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targets: [tempoService.loadBalancerTarget({
        containerName: 'tempo',
        containerPort: 4318,
      })],
      healthCheck: {
        path: '/status',
        port: '3200', // Health check on Tempo API port
        interval: cdk.Duration.seconds(30),
        timeout: cdk.Duration.seconds(5),
        healthyThresholdCount: 2,
        unhealthyThresholdCount: 3,
      },
    });


    // S3 bucket for Tempo traces
    const lokiBucket = new s3.Bucket(this, 'LokiBucket', {
        bucketName: `loki-logs-${this.account}-${this.region}`,
        removalPolicy: cdk.RemovalPolicy.DESTROY,
        autoDeleteObjects: true,
    });

    // IAM role for Tempo to access S3
    const lokiTaskRole = new iam.Role(this, 'LokiTaskRole', {
        assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
        inlinePolicies: {
            S3Access: new iam.PolicyDocument({
                statements: [
                    new iam.PolicyStatement({
                        effect: iam.Effect.ALLOW,
                        actions: ['s3:ListBucket'],
                        resources: [lokiBucket.bucketArn], // Correct: `ListBucket` applies to the bucket ARN
                    }),
                    new iam.PolicyStatement({
                        effect: iam.Effect.ALLOW,
                        actions: ['s3:GetObject', 's3:PutObject', 's3:DeleteObject'],
                        resources: [`${lokiBucket.bucketArn}/*`], // Correct: Object-level permissions apply to objects
                    }),
                ],
            }),
        },
    });

    // Loki (Logging) - ECS Service with EFS persistent storage
    const lokiTaskDefinition = new ecs.FargateTaskDefinition(this, 'LokiTask', {
      memoryLimitMiB: 1024,
      cpu: 512,
      taskRole: lokiTaskRole,
    });

    // Add EFS volume for Loki
    lokiTaskDefinition.addVolume({
      name: 'loki-storage',
      efsVolumeConfiguration: {
        fileSystemId: observabilityFileSystem.fileSystemId,
        transitEncryption: 'ENABLED',
        authorizationConfig: {
          accessPointId: lokiAccessPoint.accessPointId,
          iam: 'ENABLED',
        },
        rootDirectory: '/',
      },
    });

    const lokiContainer = lokiTaskDefinition.addContainer('loki', {
      image: ecs.ContainerImage.fromRegistry('grafana/loki:2.9.0'),
      memoryLimitMiB: 512,
      portMappings: [
        { containerPort: 3100, protocol: ecs.Protocol.TCP },
      ],
      stopTimeout: cdk.Duration.seconds(120),
      logging: ecs.LogDrivers.awsLogs({
        streamPrefix: 'loki',
        logGroup: new logs.LogGroup(this, 'LokiLogGroup', {
          logGroupName: '/ecs/loki',
          removalPolicy: cdk.RemovalPolicy.DESTROY,
        }),
      }),
      entryPoint: ['/bin/sh', '-c'],
      command: [`
        mkdir -p /mnt/loki/chunks /mnt/loki/rules;
        cat > /etc/loki/loki-config.yaml << 'EOF'
auth_enabled: false

server:
  http_listen_port: 3100
  log_level: info

common:
  path_prefix: /mnt/loki
  replication_factor: 1
  storage:
    filesystem:
      chunks_directory: /mnt/loki/chunks
      rules_directory: /mnt/loki/rules
  ring:
    kvstore:
      store: inmemory

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100

schema_config:
  configs:
    - from: 2023-07-01
      store: tsdb
      object_store: s3
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: /mnt/loki/index
    cache_location: /mnt/loki/cache
    cache_ttl: 24h
  aws:
    bucketnames: ${lokiBucket.bucketName}
    endpoint: s3.${this.region}.amazonaws.com
    region: ${this.region}
    insecure: false
    s3forcepathstyle: false
  
chunk_store_config:
  chunk_cache_config:
    embedded_cache:
      enabled: true
      max_size_mb: 500

compactor:
  working_directory: /tmp/loki/compactor
  compaction_interval: 24h
  retention_enabled: false

analytics:
  reporting_enabled: false
EOF
        exec /usr/bin/loki -config.file=/etc/loki/loki-config.yaml -target=all
      `],
    });

    // Mount EFS volume to Loki container
    lokiContainer.addMountPoints({
      sourceVolume: 'loki-storage',
      containerPath: '/mnt/loki',
      readOnly: false,
    });

    const lokiService = new ecs.FargateService(this, 'LokiService', {
      cluster,
      taskDefinition: lokiTaskDefinition,
      desiredCount: 1,
      securityGroups: [ecsSecurityGroup],
      vpcSubnets: {
        subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
      },
      assignPublicIp: false,
    });

    // Add Application Load Balancer for Loki
    const lokiLoadBalancer = new elbv2.ApplicationLoadBalancer(this, 'LokiLoadBalancer', {
      vpc,
      internetFacing: true,
    });

    const lokiListener = lokiLoadBalancer.addListener('LokiListener', {
      port: 3100,
      protocol: elbv2.ApplicationProtocol.HTTP,
    });

    lokiListener.addTargets('LokiTargets', {
      port: 3100,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targets: [lokiService],
      healthCheck: {
        path: '/ready',
        interval: cdk.Duration.seconds(30),
        timeout: cdk.Duration.seconds(5),
        healthyThresholdCount: 2,
        unhealthyThresholdCount: 3,
      },
    });

    // Self-hosted Grafana Service
    const grafanaTaskDefinition = new ecs.FargateTaskDefinition(this, 'GrafanaTask', {
      memoryLimitMiB: 1024,
      cpu: 512,
    });

    // Grant Grafana permissions to query Prometheus
    grafanaTaskDefinition.addToTaskRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['aps:QueryMetrics', 'aps:GetSeries', 'aps:GetLabels', 'aps:GetMetricMetadata'],
      resources: [prometheusWorkspace.attrArn],
    }));

    const grafanaContainer = grafanaTaskDefinition.addContainer('grafana', {
      image: ecs.ContainerImage.fromRegistry('grafana/grafana:latest'),
      memoryLimitMiB: 1024,
      portMappings: [{ containerPort: 3000, protocol: ecs.Protocol.TCP }],
      logging: ecs.LogDrivers.awsLogs({
        streamPrefix: 'grafana',
        logGroup: new logs.LogGroup(this, 'GrafanaLogGroup', {
          logGroupName: '/ecs/grafana',
          removalPolicy: cdk.RemovalPolicy.DESTROY,
        }),
      }),
      environment: {
        GF_SECURITY_ADMIN_USER: 'admin',
        GF_SECURITY_ADMIN_PASSWORD: 'admin',
        GF_SERVER_ROOT_URL: 'http://localhost:3000',
        GF_AUTH_ANONYMOUS_ENABLED: 'false',
        GF_USERS_ALLOW_SIGN_UP: 'false',
        GF_INSTALL_PLUGINS: '',
      },
    });

    const grafanaService = new ecs.FargateService(this, 'GrafanaService', {
      cluster,
      taskDefinition: grafanaTaskDefinition,
      desiredCount: 1,
      securityGroups: [ecsSecurityGroup],
      vpcSubnets: {
        subnetType: ec2.SubnetType.PUBLIC,
      },
      assignPublicIp: true,
    });

    const grafanaLoadBalancer = new elbv2.ApplicationLoadBalancer(this, 'GrafanaLoadBalancer', {
      vpc,
      internetFacing: true,
    });

    const grafanaListener = grafanaLoadBalancer.addListener('GrafanaListener', {
      port: 80,
      protocol: elbv2.ApplicationProtocol.HTTP,
    });

    grafanaListener.addTargets('GrafanaTargets', {
      port: 3000,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targets: [grafanaService],
      healthCheck: {
        path: '/api/health',
        interval: cdk.Duration.seconds(30),
        timeout: cdk.Duration.seconds(5),
        healthyThresholdCount: 2,
        unhealthyThresholdCount: 3,
      },
    });

    new cdk.CfnOutput(this, 'GrafanaURL', {
      value: `http://${grafanaLoadBalancer.loadBalancerDnsName}`,
      description: 'Grafana Dashboard URL (admin/admin)',
    });

    // Data Processor ECS Service
    const dataProcessorTaskRole = new iam.Role(this, 'DataProcessorTaskRole', {
      assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
      inlinePolicies: {
        S3Access: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ['s3:GetObject', 's3:PutObject', 's3:DeleteObject', 's3:ListBucket'],
              resources: [dataBucket.bucketArn, `${dataBucket.bucketArn}/*`],
            }),
          ],
        }),
        PrometheusAccess: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ['aps:RemoteWrite'],
              resources: [prometheusWorkspace.attrArn],
            }),
          ],
        }),
      },
    });

    const dataProcessorTaskDefinition = new ecs.FargateTaskDefinition(this, 'DataProcessorTask', {
      memoryLimitMiB: 1024,
      cpu: 512,
      taskRole: dataProcessorTaskRole,
    });

    dataProcessorTaskDefinition.addContainer('data-processor', {
      image: ecs.ContainerImage.fromAsset('./app'),
      memoryLimitMiB: 512,
      portMappings: [
        { containerPort: 8080, protocol: ecs.Protocol.TCP }, // App port
        { containerPort: 9090, protocol: ecs.Protocol.TCP }, // Metrics port
      ],
      environment: {
        BUCKET_NAME: dataBucket.bucketName,
        OTEL_SERVICE_NAME: 'data-processor-service',
        TEMPO_ENDPOINT: `http://${tempoLoadBalancer.loadBalancerDnsName}`,
        LOKI_ENDPOINT: `http://${lokiLoadBalancer.loadBalancerDnsName}:3100`,
        PORT: '8080',
        METRICS_PORT: '9090',
        PROMETHEUS_REMOTE_WRITE_URL: `https://aps-workspaces.${this.region}.amazonaws.com/workspaces/${prometheusWorkspace.attrWorkspaceId}/api/v1/remote_write`,
        AWS_REGION: this.region,
      },
    });

    // Add Prometheus server container for scraping
    dataProcessorTaskDefinition.addContainer('prometheus-scraper', {
      image: ecs.ContainerImage.fromAsset('./prometheus'),
      memoryLimitMiB: 256,
      portMappings: [
        { containerPort: 9091, protocol: ecs.Protocol.TCP }, // Prometheus server port
      ],
      environment: {
        PROMETHEUS_REMOTE_WRITE_URL: `https://aps-workspaces.${this.region}.amazonaws.com/workspaces/${prometheusWorkspace.attrWorkspaceId}/api/v1/remote_write`,
        AWS_REGION: this.region,
      },
      command: [
        '--config.file=/etc/prometheus/prometheus.yml',
        '--storage.tsdb.path=/prometheus',
        '--web.console.libraries=/etc/prometheus/console_libraries',
        '--web.console.templates=/etc/prometheus/consoles',
        '--web.listen-address=0.0.0.0:9091',
        '--storage.tsdb.retention.time=168h',
      ],
    });

    const dataProcessorService = new ecs.FargateService(this, 'DataProcessorService', {
      cluster,
      taskDefinition: dataProcessorTaskDefinition,
      desiredCount: 1,
    });

    // Load Balancer for Data Processor
    const dataProcessorLoadBalancer = new elbv2.ApplicationLoadBalancer(this, 'DataProcessorLoadBalancer', {
      vpc,
      internetFacing: true,
    });

    const dataProcessorListener = dataProcessorLoadBalancer.addListener('DataProcessorListener', {
      port: 80,
      protocol: elbv2.ApplicationProtocol.HTTP,
    });

    dataProcessorListener.addTargets('DataProcessorTargets', {
      port: 8080,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targets: [dataProcessorService],
      healthCheck: {
        path: '/health',
        interval: cdk.Duration.seconds(30),
        timeout: cdk.Duration.seconds(5),
        healthyThresholdCount: 2,
        unhealthyThresholdCount: 3,
      },
    });

    // Metrics endpoint for Prometheus scraping
    const metricsListener = dataProcessorLoadBalancer.addListener('MetricsListener', {
      port: 9090,
      protocol: elbv2.ApplicationProtocol.HTTP,
    });

    metricsListener.addTargets('MetricsTargets', {
      port: 9090,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targets: [dataProcessorService],
      healthCheck: {
        path: '/metrics',
        interval: cdk.Duration.seconds(30),
        timeout: cdk.Duration.seconds(5),
        healthyThresholdCount: 2,
        unhealthyThresholdCount: 3,
      },
    });

    // Note: AWS Managed Grafana requires SSO to be enabled
    // Create manually via console or CLI after enabling SSO

    // Outputs
    new cdk.CfnOutput(this, 'S3BucketName', {
      value: dataBucket.bucketName,
      description: 'S3 bucket for data storage',
    });

    new cdk.CfnOutput(this, 'PrometheusWorkspaceId', {
      value: prometheusWorkspace.attrWorkspaceId,
      description: 'AWS Managed Prometheus workspace ID',
    });

    new cdk.CfnOutput(this, 'VPCId', {
      value: vpc.vpcId,
      description: 'VPC ID for ECS services',
    });

    new cdk.CfnOutput(this, 'ECSClusterName', {
      value: cluster.clusterName,
      description: 'ECS cluster name for Tempo and Loki services',
    });

    new cdk.CfnOutput(this, 'LokiLoadBalancerDNS', {
      value: lokiLoadBalancer.loadBalancerDnsName,
      description: 'Loki load balancer DNS name',
    });

    new cdk.CfnOutput(this, 'TempoLoadBalancerDNS', {
      value: tempoLoadBalancer.loadBalancerDnsName,
      description: 'Tempo load balancer DNS name',
    });

    new cdk.CfnOutput(this, 'DataProcessorLoadBalancerDNS', {
      value: dataProcessorLoadBalancer.loadBalancerDnsName,
      description: 'Data Processor load balancer DNS name',
    });

    new cdk.CfnOutput(this, 'DataProcessorEndpoint', {
      value: `http://${dataProcessorLoadBalancer.loadBalancerDnsName}`,
      description: 'Data Processor service endpoint',
    });

    new cdk.CfnOutput(this, 'MetricsEndpoint', {
      value: `http://${dataProcessorLoadBalancer.loadBalancerDnsName}:9090/metrics`,
      description: 'Prometheus metrics endpoint',
    });

    // SNS Topic for Grafana alerts
    const alertTopic = new sns.Topic(this, 'GrafanaAlertTopic', {
      topicName: 'grafana-alerts',
      displayName: 'Grafana Alert Notifications',
    });

    // Lambda function to transform Grafana alerts to custom schema
    const alertTransformerFunction = new lambda.Function(this, 'AlertTransformerFunction', {
      runtime: lambda.Runtime.NODEJS_18_X,
      handler: 'index.handler',
      code: lambda.Code.fromInline(`
const { SNSClient, PublishCommand } = require('@aws-sdk/client-sns');
const crypto = require('crypto');
const sns = new SNSClient({ region: process.env.AWS_REGION });

exports.handler = async (event) => {
    console.log('Received event:', JSON.stringify(event, null, 2));
    
    try {
        // Parse SNS message
        const snsMessage = JSON.parse(event.Records[0].Sns.Message);
        
        // Generate stable incident ID based on alert rule and labels
        const alertName = snsMessage.commonLabels?.alertname || 'unknown';
        const service = snsMessage.commonLabels?.service || 'DocStorageService';
        const severity = snsMessage.commonLabels?.severity || 'sev3';
        
        // Create stable incident ID from alert characteristics
        const incidentKey = \`\${service}:\${alertName}:\${severity}\`;
        const incidentId = crypto.createHash('md5').update(incidentKey).digest('hex').substring(0, 16);
        
        // Transform Grafana alert to custom schema
        const customEvent = {
            eventType: 'incident',
            incidentId: incidentId,
            action: mapGrafanaStatus(snsMessage.status),
            priority: mapGrafanaSeverity(severity),
            title: alertName,
            description: snsMessage.commonAnnotations?.summary || snsMessage.commonAnnotations?.description,
            timestamp: new Date().toISOString(),
            service: 'test_byo_grafana_mcp',
            data: {
                originalAlert: snsMessage,
                grafanaUrl: snsMessage.externalURL,
                labels: snsMessage.commonLabels,
                annotations: snsMessage.commonAnnotations,
                incidentKey: incidentKey
            }
        };
        
        // Publish to final SNS topic
        await sns.publish({
            TopicArn: process.env.FINAL_TOPIC_ARN,
            Message: JSON.stringify(customEvent),
            Subject: \`[\${customEvent.priority}] \${customEvent.title} - \${customEvent.action.toUpperCase()}\`
        }).promise();
        
        console.log('Successfully transformed and published alert:', customEvent);
        return { statusCode: 200, body: 'Alert processed successfully' };
        
    } catch (error) {
        console.error('Error processing alert:', error);
        throw error;
    }
};

function mapGrafanaStatus(status) {
    switch (status) {
        case 'firing': return 'created';
        case 'resolved': return 'resolved';
        default: return 'updated';
    }
}

function mapGrafanaSeverity(severity) {
    switch (severity) {
        case 'sev1': return 'CRITICAL';
        case 'sev2': return 'HIGH';
        case 'sev3': return 'MEDIUM';
        case 'sev4': return 'LOW';
        default: return 'MINIMAL';
    }
}
      `),
      environment: {
        FINAL_TOPIC_ARN: alertTopic.topicArn,
      },
    });

    // Grant Lambda permission to publish to SNS
    alertTopic.grantPublish(alertTransformerFunction);

    // Intermediate SNS topic for Grafana webhook
    const grafanaWebhookTopic = new sns.Topic(this, 'GrafanaWebhookTopic', {
      topicName: 'grafana-webhook-alerts',
      displayName: 'Grafana Webhook Alerts (Raw)',
    });

    // Subscribe Lambda to the webhook topic
    grafanaWebhookTopic.addSubscription(
      new snsSubscriptions.LambdaSubscription(alertTransformerFunction)
    );

    new cdk.CfnOutput(this, 'GrafanaWebhookTopicArn', {
      value: grafanaWebhookTopic.topicArn,
      description: 'SNS Topic ARN for Grafana webhook notifications',
    });

    new cdk.CfnOutput(this, 'FinalAlertTopicArn', {
      value: alertTopic.topicArn,
      description: 'SNS Topic ARN for final transformed alert notifications',
    });

    new cdk.CfnOutput(this, 'EfsFileSystemId', {
      value: observabilityFileSystem.fileSystemId,
      description: 'EFS File System ID for persistent storage',
    });

    // Lambda function for automated testing
    const testRunnerFunction = new lambda.Function(this, 'TestRunnerFunction', {
      runtime: lambda.Runtime.PYTHON_3_9,
      handler: 'test-runner.lambda_handler',
      code: lambda.Code.fromAsset('lambda'),
      timeout: cdk.Duration.seconds(30),
      environment: {
        LOAD_BALANCER_URL: `http://${dataProcessorLoadBalancer.loadBalancerDnsName}`
      }
    });

    // EventBridge rule to trigger Lambda every minute
    new events.Rule(this, 'TestRunnerRule', {
      schedule: events.Schedule.rate(cdk.Duration.minutes(1)),
      targets: [
        new targets.LambdaFunction(testRunnerFunction)
      ]
    });

  }
}

// CDK App instantiation
const app = new cdk.App();
new GrafanaObservabilityStackStack(app, 'GrafanaObservabilityStackStack', {
  /* If you don't specify 'env', this stack will be environment-agnostic.
   * Account/Region-dependent features and context lookups will not work,
   * but a single synthesized template can be deployed anywhere. */

  /* Uncomment the next line to specialize this stack for the AWS Account
   * and Region that are implied by the current CLI configuration. */
  // env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION },

  /* Uncomment the next line if you know exactly what Account and Region you
   * want to deploy the stack to. */
  // env: { account: '123456789012', region: 'us-east-1' },

  /* For more information, see https://docs.aws.amazon.com/cdk/latest/guide/environments.html */
});
