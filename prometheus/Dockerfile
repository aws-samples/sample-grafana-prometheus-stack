# Start from the official Prometheus image.
FROM --platform=linux/amd64 prom/prometheus:latest

# Create a new directory for the entrypoint script inside the
# Prometheus home directory.
RUN mkdir -p /etc/prometheus/scripts/

# Copy the entrypoint script and the prometheus config file.
COPY prometheus.yml /etc/prometheus/prometheus.yml
COPY entrypoint.sh /etc/prometheus/scripts/entrypoint.sh

# Set the entrypoint to your new script location.
ENTRYPOINT ["/etc/prometheus/scripts/entrypoint.sh"]