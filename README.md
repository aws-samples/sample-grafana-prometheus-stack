# Grafana Observability Stack

A complete observability stack demonstrating metrics, traces, and logs collection using AWS Managed Grafana, Prometheus, Tempo, and Loki with a sample Flask application.

## 🏗️ Architecture Overview

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
                    │  │ Prometheus      │ │ ◄── Metrics
                    │  │ (Scraper)       │ │
                    │  └─────────────────┘ │
                    │           │          │
                    │           ▼          │
                    │  ┌─────────────────┐ │
                    │  │ AWS Managed     │ │ ◄── Storage
                    │  │ Prometheus      │ │
                    │  └─────────────────┘ │
                    │                      │
                    │  ┌─────────────────┐ │
                    │  │ Tempo           │ │ ◄── Traces
                    │  │ (ECS)           │ │
                    │  └─────────────────┘ │
                    │                      │
                    │  ┌─────────────────┐ │
                    │  │ Loki            │ │ ◄── Logs
                    │  │ (ECS)           │ │
                    │  └─────────────────┘ │
                    │                      │
                    │  ┌─────────────────┐ │
                    │  │ Grafana         │ │ ◄── Visualization
                    │  │ (ECS)           │ │     (Self-hosted)
                    │  └─────────────────┘ │
                    └──────────────────────┘
```

## 🚀 Components

### Core Infrastructure
- **ECS Fargate Cluster**: Container orchestration platform
- **Application Load Balancers**: Traffic routing and health checks
- **VPC with Public Subnets**: Network isolation and internet access
- **S3 Bucket**: Data storage for the sample application

### Observability Stack
- **Self-hosted Grafana (ECS)**: Centralized visualization and dashboards with automated setup
- **AWS Managed Prometheus**: Scalable metrics storage and querying
- **Tempo (ECS)**: Distributed tracing collection and storage
- **Loki (ECS)**: Log aggregation and querying
- **Prometheus Scraper (ECS)**: Metrics collection from application

### Sample Application
- **Data Processor Service**: Flask-based REST API with full observability
- **Load Balancer**: Direct access to ECS services with health checks
- **OpenTelemetry Integration**: Automatic instrumentation for traces and metrics
- **Automated Testing**: Lambda function for continuous API testing

## 📊 Observability Implementation

### Metrics Collection
The Flask application exposes Prometheus metrics on port `9090/metrics`:

```python
# Counter for HTTP requests
http_requests_total = Counter(
    'http_requests_total',
    'Total HTTP requests',
    ['method', 'endpoint', 'status']
)

# Histogram for request duration
http_request_duration = Histogram(
    'http_request_duration_seconds',
    'HTTP request duration'
)
```

**Metadata Used:**
- `method`: HTTP method (GET, POST, etc.)
- `endpoint`: API endpoint path
- `status`: HTTP response status code

### Traces Collection
OpenTelemetry automatic instrumentation captures:

```python
# Service configuration
OTEL_SERVICE_NAME = 'data-processor-service'
OTEL_RESOURCE_ATTRIBUTES = 'service.name=data-processor-service'

# Automatic instrumentation for:
# - Flask requests/responses
# - S3 operations (boto3)
# - HTTP client calls
```

**Metadata Used:**
- `service.name`: Service identifier
- `http.method`: HTTP method
- `http.url`: Request URL
- `http.status_code`: Response status
- `aws.service`: AWS service name (S3)
- `aws.operation`: AWS operation name

### Logs Collection
Structured logging with correlation IDs:

```python
# Log format with trace correlation
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

# Automatic log correlation with traces via OpenTelemetry
```

**Metadata Used:**
- `timestamp`: Log event time
- `level`: Log level (INFO, ERROR, etc.)
- `service`: Service name
- `trace_id`: Distributed trace identifier
- `span_id`: Span identifier for correlation

## 📁 Project Structure

```
├── app/                    # Flask application source code
├── dashboards/            # Grafana dashboard configurations
├── docs/                  # Additional documentation
├── grafana/               # Grafana-related components
│   ├── grafana-observability-stack.ts # CDK app entry point & stack definition
│   ├── setup-grafana.sh   # Grafana workspace setup
│   └── configure-grafana.sh # Data source configuration
├── lambda/                # Lambda function for automated testing
├── prometheus/            # Prometheus configuration files
├── scripts/               # General deployment scripts
│   └── complete-setup.sh  # One-command deployment
└── tests/                 # Test files and scripts
    └── test.sh            # Comprehensive testing script
```

## 🛠️ Deployment Guide

### Prerequisites
- AWS CLI configured with appropriate permissions
- AWS CDK installed: `npm install -g aws-cdk`
- Docker running locally

### One-Command Deployment

```bash
scripts/complete-setup.sh
```

**Note**: The deployment is fully automated. No manual steps required after running the script.

### What complete-setup.sh Does

#### Step 1: Infrastructure Deployment
```bash
# Runs: npm install, npm run build, cdk bootstrap, cdk deploy --require-approval never
```

**Creates:**
- ECS Fargate cluster with 4 services:
  - Data Processor (Flask app + Prometheus scraper)
  - Tempo (tracing backend)
  - Loki (logging backend)
  - Grafana (visualization dashboard)
- Application Load Balancers for each service
- AWS Managed Prometheus workspace
- S3 bucket for data storage
- Lambda function for automated testing
- IAM roles and policies

#### Step 2: Data Source Configuration
```bash
# Automatic configuration during deployment
```

**Configures:**
- **Prometheus Data Source**: 
  ```json
  {
    "name": "Prometheus",
    "type": "prometheus",
    "url": "https://aps-workspaces.us-west-2.amazonaws.com/workspaces/{workspace-id}/",
    "access": "proxy",
    "isDefault": true,
    "jsonData": {
      "sigV4Auth": true,
      "sigV4AuthType": "default"
    }
  }
  ```

- **Loki Data Source**:
  ```json
  {
    "name": "Loki",
    "type": "loki", 
    "url": "http://{loki-lb-dns}:3100",
    "access": "proxy"
  }
  ```

- **Tempo Data Source**:
  ```json
  {
    "name": "Tempo",
    "type": "tempo",
    "url": "http://{tempo-lb-dns}:3200",
    "access": "proxy",
    "jsonData": {
      "tracesToLogs": { "datasourceUid": "loki" },
      "tracesToMetrics": { "datasourceUid": "prometheus" }
    }
  }
  ```

#### Step 4: Testing & Validation
```bash
tests/test.sh    # Generate sample data and test connectivity
```

## 🔧 Main Service Components

### Data Processor Service (Flask Application)

**Location**: `app/app.py`

**Key Features:**
- RESTful API with health checks
- S3 integration for data persistence
- Full OpenTelemetry instrumentation
- Prometheus metrics exposition
- Structured logging

**API Endpoints:**
```
GET  /health           # Health check
POST /data             # Store data in S3
GET  /data/{key}       # Retrieve data from S3
GET  /metrics          # Prometheus metrics
```

**Container Configuration:**
```typescript
// Two containers in the same task:
// 1. Flask application (port 8080, 9090)
// 2. Prometheus scraper (port 9091)
```

### Automated Testing (Lambda Function)

**Location**: `lambda/test-runner.py`

**Key Features:**
- Runs every minute via EventBridge
- Makes 6 HTTP calls to Load Balancer:
  - 2 successful POST requests (write documents)
  - 2 successful GET requests (read documents)
  - 1 client error GET (404 for nonexistent document)
  - 1 service error POST (invalid JSON for 400 error)
- Generates continuous observability data
- Logs results to CloudWatch

### Prometheus Scraper Configuration

**Location**: `prometheus/prometheus.yml`

```yaml
global:
  scrape_interval: 15s

remote_write:
  - url: "https://aps-workspaces.us-east-1.amazonaws.com/workspaces/{workspace-id}/api/v1/remote_write"
    sigv4:
      region: us-east-1

scrape_configs:
  - job_name: 'data-processor'
    static_configs:
      - targets: ['localhost:9090']  # Same task network
    scrape_interval: 5s
```

## 📈 Accessing Your Observability Stack

### 1. Grafana Dashboard
```bash
# Get Grafana URL from stack outputs
aws cloudformation describe-stacks \
  --stack-name GrafanaObservabilityStackStack \
  --region us-west-2 \
  --query 'Stacks[0].Outputs[?OutputKey==`GrafanaURL`].OutputValue' \
  --output text
```

**Login credentials:**
- Username: `admin`
- Password: `admin`

### 2. Service Endpoints
Check CloudFormation stack outputs:
```bash
aws cloudformation describe-stacks \
  --stack-name GrafanaObservabilityStackStack \
  --region us-east-1 \
  --query 'Stacks[0].Outputs'
```

### 3. Generate Sample Data
```bash
tests/test.sh  # Creates metrics, traces, and logs
```

## 🧹 Cleanup

```bash
# Destroy all resources
cdk destroy
```

## 📚 Additional Resources

- [AWS Managed Prometheus Documentation](https://docs.aws.amazon.com/prometheus/)
- [OpenTelemetry Python Documentation](https://opentelemetry.io/docs/languages/python/)
- [Grafana Tempo Documentation](https://grafana.com/docs/tempo/)
- [Grafana Loki Documentation](https://grafana.com/docs/loki/)

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.