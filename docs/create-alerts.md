# Create DocStorageService Alerts

## Manual Creation Steps

### Alert 1: High Error Rate (Sev3)

1. **Alerting** → **Alert rules** → **New alert rule**
2. **Rule name**: `DocStorageService_High_Error_Rate_Sev3`
3. **Section 1 - Set a query and alert condition**:
   - Select `Prometheus` data source
   - Switch to **Code** mode (toggle in query editor)
   - Enter query: `rate(doc_operations_total{service="DocStorageService", status_type="service_error"}[1m]) * 60`
   - Click **+ Expression** → **Reduce**
   - Function: `Last`
   - Click **+ Expression** → **Threshold**
   - IS ABOVE: `2`
   - Set this as alert condition (click the eye icon)
4. **Section 2 - Alert evaluation behavior**:
   - Folder: Create new `DocStorageService_Alerts`
   - Evaluation group: Create new `DocStorageService_Alerts`
   - Evaluation interval: `1m`
   - For: `0m`
5. **Section 3 - Add details**:
   - Summary: `DocStorageService has high service error rate (Sev3)`
   - Description: `Experiencing {{ $value }} errors/min (threshold: 2)`
   - Labels: Add `severity=sev3`, `service=DocStorageService`
6. **Save and exit**

### Alert 2: High Error Rate (Sev2)

Repeat above steps with:
- Rule name: `DocStorageService_High_Error_Rate_Sev2`
- Threshold: `5`
- Summary: `DocStorageService has critical service error rate (Sev2)`
- Labels: `severity=sev2`, `service=DocStorageService`

## Test

```bash
tests/test-scenario1-invalid-json.sh
```

Check **Alerting** → **Alert rules** after 1-2 minutes.
