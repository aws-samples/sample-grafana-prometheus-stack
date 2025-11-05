import json
import boto3
import os
import logging
import traceback
from datetime import datetime
import uuid
import time
import requests
from flask import Flask, request, jsonify, Response, g
from opentelemetry import trace, metrics
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.resources import Resource
from prometheus_client import Counter, Histogram, generate_latest, CollectorRegistry, push_to_gateway
import threading

app = Flask(__name__)

@app.before_request
def before_request():
    g.request_id = str(uuid.uuid4())[:8]

# Get service endpoints
TEMPO_ENDPOINT = os.environ.get('TEMPO_ENDPOINT', '')
LOKI_ENDPOINT = os.environ.get('LOKI_ENDPOINT', '')
PORT = int(os.environ.get('PORT', 8080))
METRICS_PORT = int(os.environ.get('METRICS_PORT', 9090))
PROMETHEUS_REMOTE_WRITE_URL = os.environ.get('PROMETHEUS_REMOTE_WRITE_URL', '')
AWS_REGION = os.environ.get('AWS_REGION', 'us-west-2')

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configure OpenTelemetry with Tempo exporter
trace_provider = TracerProvider(
    resource=Resource.create({"service.name": "DocStorageService"})
)
if TEMPO_ENDPOINT:
    try:
        # Extract base URL and replace port for OTLP endpoint
        tempo_base = TEMPO_ENDPOINT.replace(':3200', '')  # Remove :3200 if present
        otlp_endpoint = f"{tempo_base}:4318/v1/traces"
        
        trace_provider.add_span_processor(
            BatchSpanProcessor(
                OTLPSpanExporter(
                    endpoint=otlp_endpoint,
                    timeout=2
                )
            )
        )
        logger.info(f"Configured Tempo exporter: {otlp_endpoint}")
    except Exception as e:
        logger.warning(f"Failed to configure Tempo exporter: {e}")

trace.set_tracer_provider(trace_provider)
tracer = trace.get_tracer("DocStorageService")

metrics.set_meter_provider(MeterProvider())
meter = metrics.get_meter("DocStorageService")

# Business-oriented Prometheus metrics
registry = CollectorRegistry()
DOC_OPERATIONS_TOTAL = Counter('doc_operations_total', 'Total document operations', ['service', 'operation', 'status_type'], registry=registry)
DOC_OPERATION_DURATION = Histogram('doc_operation_duration_seconds', 'Document operation duration', ['service', 'operation'], registry=registry)

s3 = boto3.client('s3')
BUCKET_NAME = os.environ['BUCKET_NAME']

def push_metrics_to_prometheus():
    """Push metrics to AWS Managed Prometheus using remote write"""
    if not PROMETHEUS_REMOTE_WRITE_URL:
        logger.debug("Prometheus remote write URL not configured")
        return
        
    try:
        # Use AWS SigV4 authentication for remote write
        session = boto3.Session()
        credentials = session.get_credentials()
        
        # For now, just log that we would push metrics
        # AWS Managed Prometheus remote write requires special handling
        logger.info("Would push metrics to AWS Managed Prometheus")
        
    except Exception as e:
        logger.warning(f"Failed to push metrics to Prometheus: {e}")

def push_logs_to_loki(level, message, operation=None, doc_key=None):
    """Push logs to Loki with business context"""
    if not LOKI_ENDPOINT:
        logger.debug("Loki endpoint not configured")
        return
        
    try:
        labels = {
            'service': 'DocStorageService',
            'level': level,
            'request_id': getattr(g, 'request_id', 'unknown')
        }
        if operation:
            labels['operation'] = operation
        if doc_key:
            labels['doc_key'] = doc_key
        
        payload = {
            'streams': [{
                'stream': labels,
                'values': [[str(int(time.time() * 1000000000)), message]]
            }]
        }
        
        response = requests.post(
            f"{LOKI_ENDPOINT}/loki/api/v1/push", 
            json=payload, 
            timeout=3
        )
        if response.status_code == 204:
            logger.debug("Successfully pushed to Loki")
        else:
            logger.warning(f"Loki returned status {response.status_code}")
            
    except requests.exceptions.ConnectTimeout:
        logger.warning(f"Loki connection timeout: {LOKI_ENDPOINT}")
    except requests.exceptions.ConnectionError:
        logger.warning(f"Loki connection error: {LOKI_ENDPOINT}")
    except Exception as e:
        logger.warning(f"Failed to push to Loki: {e}")

@app.route('/health')
def health_check():
    return jsonify({'status': 'healthy', 'timestamp': datetime.now().isoformat()})

@app.route('/metrics')
def metrics_endpoint():
    return Response(generate_latest(registry), mimetype='text/plain')

@app.route('/data', methods=['POST'])
def post_data():
    start_time = time.time()
    
    with tracer.start_as_current_span("WriteDoc") as span:
        try:
            span.set_attribute("service.name", "DocStorageService")
            span.set_attribute("operation", "WriteDoc")
            span.set_attribute("request_id", g.request_id)
            
            log_msg = f"[{g.request_id}] Starting WriteDoc operation"
            logger.info(log_msg)
            push_logs_to_loki('info', log_msg, operation='WriteDoc')
            
            body = request.get_json()
            if body is None:
                raise ValueError("Request must contain valid JSON data")

            with tracer.start_as_current_span("s3_store_document") as s3_span:
                key = f"documents/{datetime.now().isoformat()}-{uuid.uuid4()}.json"
                
                s3_span.set_attribute("doc.key", key)
                s3_span.set_attribute("storage.type", "s3")
                s3_span.set_attribute("doc.size_bytes", len(json.dumps(body)))
                
                log_msg = f"[{g.request_id}] WriteDoc - Starting S3 put_object for key: {key}"
                logger.info(log_msg)
                push_logs_to_loki('info', log_msg, operation='WriteDoc', doc_key=key)
                
                s3.put_object(
                    Bucket=BUCKET_NAME,
                    Key=key,
                    Body=json.dumps(body),
                    ContentType='application/json'
                )
                
                log_msg = f"[{g.request_id}] WriteDoc - S3 put_object completed successfully for key: {key}"
                logger.info(log_msg)
                push_logs_to_loki('info', log_msg, operation='WriteDoc', doc_key=key)
                
                duration = time.time() - start_time
                DOC_OPERATION_DURATION.labels(service='DocStorageService', operation='WriteDoc').observe(duration)
                DOC_OPERATIONS_TOTAL.labels(service='DocStorageService', operation='WriteDoc', status_type='success').inc()
                
                log_msg = f"[{g.request_id}] WriteDoc operation completed successfully in {duration:.3f}s - document stored with key: {key}"
                logger.info(log_msg)
                push_logs_to_loki('info', log_msg, operation='WriteDoc', doc_key=key)
                
                threading.Thread(target=push_metrics_to_prometheus, daemon=True).start()
                
                return jsonify({'message': 'Document stored successfully', 'key': key})
                
        except Exception as e:
            duration = time.time() - start_time
            DOC_OPERATION_DURATION.labels(service='DocStorageService', operation='WriteDoc').observe(duration)
            DOC_OPERATIONS_TOTAL.labels(service='DocStorageService', operation='WriteDoc', status_type='service_error').inc()
            
            span.set_attribute("error", True)
            span.set_attribute("error.message", str(e))
            
            error_msg = f"[{g.request_id}] WriteDoc operation failed after {duration:.3f}s due to service error: {str(e)}"
            stack_trace = traceback.format_exc()
            logger.error(f"{error_msg}\nStack trace:\n{stack_trace}")
            push_logs_to_loki('error', f"{error_msg}\nStack trace: {stack_trace}", operation='WriteDoc')
            
            return jsonify({'error': 'Service error occurred'}), 500

@app.route('/data/<path:key>')
def get_data(key):
    start_time = time.time()
    
    with tracer.start_as_current_span("ReadDoc") as span:
        try:
            span.set_attribute("service.name", "DocStorageService")
            span.set_attribute("operation", "ReadDoc")
            span.set_attribute("doc.key", key)
            span.set_attribute("request_id", g.request_id)
            
            log_msg = f"[{g.request_id}] Starting ReadDoc operation for key: {key}"
            logger.info(log_msg)
            push_logs_to_loki('info', log_msg, operation='ReadDoc', doc_key=key)
            
            with tracer.start_as_current_span("s3_retrieve_document") as s3_span:
                s3_span.set_attribute("doc.key", key)
                s3_span.set_attribute("storage.type", "s3")
                
                log_msg = f"[{g.request_id}] ReadDoc - Starting S3 get_object for key: {key}"
                logger.info(log_msg)
                push_logs_to_loki('info', log_msg, operation='ReadDoc', doc_key=key)
                
                try:
                    response = s3.get_object(Bucket=BUCKET_NAME, Key=key)
                    data = json.loads(response['Body'].read())
                    
                    log_msg = f"[{g.request_id}] ReadDoc - S3 get_object completed successfully for key: {key}"
                    logger.info(log_msg)
                    push_logs_to_loki('info', log_msg, operation='ReadDoc', doc_key=key)
                    
                    duration = time.time() - start_time
                    DOC_OPERATION_DURATION.labels(service='DocStorageService', operation='ReadDoc').observe(duration)
                    DOC_OPERATIONS_TOTAL.labels(service='DocStorageService', operation='ReadDoc', status_type='success').inc()
                    
                    log_msg = f"[{g.request_id}] ReadDoc operation completed successfully in {duration:.3f}s for key: {key}"
                    logger.info(log_msg)
                    push_logs_to_loki('info', log_msg, operation='ReadDoc', doc_key=key)
                    
                    return jsonify(data)
                    
                except s3.exceptions.NoSuchKey:
                    duration = time.time() - start_time
                    DOC_OPERATION_DURATION.labels(service='DocStorageService', operation='ReadDoc').observe(duration)
                    DOC_OPERATIONS_TOTAL.labels(service='DocStorageService', operation='ReadDoc', status_type='client_error').inc()
                    
                    log_msg = f"[{g.request_id}] ReadDoc failed after {duration:.3f}s - document not found for key: {key}"
                    logger.warning(log_msg)
                    push_logs_to_loki('warning', log_msg, operation='ReadDoc', doc_key=key)
                    
                    return jsonify({'error': 'Document not found'}), 404
                    
        except Exception as e:
            duration = time.time() - start_time
            DOC_OPERATION_DURATION.labels(service='DocStorageService', operation='ReadDoc').observe(duration)
            DOC_OPERATIONS_TOTAL.labels(service='DocStorageService', operation='ReadDoc', status_type='service_error').inc()
            
            span.set_attribute("error", True)
            span.set_attribute("error.message", str(e))
            
            error_msg = f"[{g.request_id}] ReadDoc operation failed after {duration:.3f}s due to service error: {str(e)}"
            stack_trace = traceback.format_exc()
            logger.error(f"{error_msg}\nStack trace:\n{stack_trace}")
            push_logs_to_loki('error', f"{error_msg}\nStack trace: {stack_trace}", operation='ReadDoc', doc_key=key)
            
            return jsonify({'error': 'Service error occurred'}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=PORT, debug=False)
