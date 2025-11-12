FROM grafana/grafana:latest

USER root

# Install AWS CLI v2 for proper ECS credential chain support
RUN apk add --no-cache aws-cli

# Configure AWS SDK to use ECS container credentials
ENV AWS_SDK_LOAD_CONFIG=1 \
    AWS_EC2_METADATA_DISABLED=true

USER grafana
