FROM --platform=linux/amd64 grafana/grafana:latest

COPY provisioning /etc/grafana/provisioning

HEALTHCHECK --interval=10s --timeout=3s --start-period=45s --retries=13 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3000/api/health || exit 1
