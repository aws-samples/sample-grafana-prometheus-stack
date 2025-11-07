# Grafana Observability Stack

Complete observability stack with Grafana, Prometheus, Tempo, and Loki on AWS ECS, featuring a sample Flask application with automated testing.

## Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│  Load Balancer  │────│  Data Processor  │────│   S3 Bucket     │
│                 │    │   (Flask App)    │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                │
                                ▼
                    ┌──────────────────────┐
                    │   Observability      │
                    │                      │
                    │  ┌─────────────────┐ │
                    │  │ AWS Managed     │ │ ◄── Metrics
                    │  │ Prometheus      │ │
                    │  └─────────────────┘ │
                    │                      │
                    │  ┌─────────────────┐ │
                    │  │ Tempo (ECS)     │ │ ◄── Traces
                    │  └─────────────────┘ │
                    │                      │
                    │  ┌─────────────────┐ │
                    │  │ Loki (ECS)      │ │ ◄── Logs
                    │  └─────────────────┘ │
                    │                      │
                    │  ┌─────────────────┐ │
                    │  │ Grafana (ECS)   │ │ ◄── Visualization
                    │  └─────────────────┘ │
                    └──────────────────────┘
```

## Components

- **Self-hosted Grafana (ECS)**: Visualization with automated data source configuration
- **AWS Managed Prometheus**: Metrics storage
- **Tempo (ECS)**: Distributed tracing
- **Loki (ECS)**: Log aggregation
- **Data Processor**: Flask API with OpenTelemetry instrumentation
- **Lambda Testing**: Automated API calls every minute

## Deployment

### Prerequisites
- AWS CLI configured
- AWS CDK installed: `npm install -g aws-cdk`
- Docker running

### Deploy

```bash
scripts/complete-setup.sh
```

Deployment is fully automated and creates:
- ECS Fargate cluster with 4 services (Data Processor, Tempo, Loki, Grafana)
- Application Load Balancers
- AWS Managed Prometheus workspace
- S3 bucket for data storage
- Lambda function for automated testing
- Grafana data sources (Prometheus, Loki, Tempo) with trace/log correlation

## Accessing Your Stack

### Get Grafana URL
```bash
aws cloudformation describe-stacks \
  --stack-name GrafanaObservabilityStackStack \
  --region us-west-2 \
  --query 'Stacks[0].Outputs[?OutputKey==`GrafanaURL`].OutputValue' \
  --output text
```

**Login:** Username `admin`, Password `admin`

### Generate Sample Data
```bash
tests/test.sh
```

### Simulate Failure Scenario
```bash
tests/test-scenario1-invalid-json.sh
```

This generates errors and failures for testing observability dashboards and alerts.

## Agentic Observability

This stack works with the [Grafana MCP Server](https://github.com/aws-samples/grafana-mcp-server) to provide LLM-powered observability analysis. The MCP server enables AI agents to:
- Query Grafana dashboards and metrics
- Analyze traces and logs
- Investigate incidents and anomalies
- Provide intelligent troubleshooting recommendations

Deploy both stacks together for a complete agentic observability solution.

## Cleanup

```bash
cdk destroy
```

## License

This library is licensed under the MIT-0 License. See the LICENSE file.