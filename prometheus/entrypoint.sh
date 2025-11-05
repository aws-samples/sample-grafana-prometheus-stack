#!/bin/sh

# The entrypoint script will replace the placeholder in the config file
# with the actual value of the environment variable.
echo "Substituting PROMETHEUS_REMOTE_WRITE_URL into prometheus.yml"
sed -i "s|{{PROMETHEUS_REMOTE_WRITE_URL}}|$PROMETHEUS_REMOTE_WRITE_URL|g" /etc/prometheus/prometheus.yml

# Now, execute the original Prometheus command.
exec /bin/prometheus "$@"