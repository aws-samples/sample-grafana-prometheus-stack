import json
import urllib3
import os
import time

def lambda_handler(event, context):
    lb_url = os.environ['LOAD_BALANCER_URL']
    http = urllib3.PoolManager()
    
    results = []
    
    # 1. POST /data - Write doc success
    try:
        response = http.request('POST', f'{lb_url}/data',
            body=json.dumps({"test": "success1", "data": {"value": 42}, "key": "test-doc-1"}),
            headers={'Content-Type': 'application/json'})
        results.append({"test": "write_success_1", "status": response.status})
    except Exception as e:
        results.append({"test": "write_success_1", "error": str(e)})
    
    # 2. POST /data - Write doc success (different key)
    try:
        response = http.request('POST', f'{lb_url}/data',
            body=json.dumps({"test": "success2", "data": {"value": 100}, "key": "test-doc-2"}),
            headers={'Content-Type': 'application/json'})
        results.append({"test": "write_success_2", "status": response.status})
    except Exception as e:
        results.append({"test": "write_success_2", "error": str(e)})
    
    # 3. GET /data - Read doc success
    try:
        response = http.request('GET', f'{lb_url}/data/documents/test-doc-1.json')
        results.append({"test": "read_success_1", "status": response.status})
    except Exception as e:
        results.append({"test": "read_success_1", "error": str(e)})
    
    # 4. GET /data - Read doc success (different doc)
    try:
        response = http.request('GET', f'{lb_url}/data/documents/test-doc-2.json')
        results.append({"test": "read_success_2", "status": response.status})
    except Exception as e:
        results.append({"test": "read_success_2", "error": str(e)})
    
    # 5. GET /data - Client error (404)
    try:
        response = http.request('GET', f'{lb_url}/data/nonexistent-document')
        results.append({"test": "client_error_404", "status": response.status})
    except Exception as e:
        results.append({"test": "client_error_404", "error": str(e)})
    
    # 6. POST /data - Service error (invalid JSON)
    try:
        response = http.request('POST', f'{lb_url}/data',
            body="invalid json text",
            headers={'Content-Type': 'application/json'})
        results.append({"test": "service_error_400", "status": response.status})
    except Exception as e:
        results.append({"test": "service_error_400", "error": str(e)})
    
    print(f"Test results: {json.dumps(results)}")
    
    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': 'Test completed',
            'results': results,
            'timestamp': int(time.time())
        })
    }
