#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# --- SSM agent: on Ubuntu AWS AMIs it ships as a SNAP, not a normal service.
# Ensure it's installed and started so the node registers with SSM. ---
snap list amazon-ssm-agent >/dev/null 2>&1 || snap install amazon-ssm-agent --classic || true
snap start amazon-ssm-agent || true

# --- Base packages (a mirror hiccup must not abort the whole bootstrap) ---
apt-get update -y || true
apt-get install -y docker.io
systemctl enable --now docker

# --- AWS CLI is NOT preinstalled on Ubuntu; deploy.sh needs it for Secrets Manager ---
snap install aws-cli --classic || apt-get install -y awscli || true

mkdir -p /opt/deploy

# Non-secret runtime config, written by Terraform at first boot.
cat > /opt/deploy/app.env <<EOF
REGION=${region}
SECRET_ARN=${secret_arn}
APP_PORT=${app_port}
DB_HOST=${db_host}
DB_NAME=${db_name}
DB_USER=${db_user}
EOF

# Reusable deploy script. The CD pipeline calls this via SSM:
#   sudo /opt/deploy/deploy.sh <image>
cat > /opt/deploy/deploy.sh <<'DEPLOY'
#!/bin/bash
set -euxo pipefail
# SSM RunShellScript uses a minimal PATH that omits /snap/bin, where the
# snap-installed aws CLI lives. Add it so `aws` is found during deploys.
export PATH="$PATH:/snap/bin:/usr/local/bin"

IMAGE="$${1:-}"
if [ -z "$IMAGE" ]; then echo "usage: deploy.sh <image:tag>"; exit 1; fi

source /opt/deploy/app.env

DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --region "$REGION" \
  --query SecretString --output text)

docker pull "$IMAGE"
docker rm -f petclinic 2>/dev/null || true
docker run -d --name petclinic --restart unless-stopped \
  -p "$APP_PORT:8080" \
  -e SPRING_PROFILES_ACTIVE=postgres \
  -e SPRING_DATASOURCE_URL="jdbc:postgresql://$DB_HOST:5432/$DB_NAME" \
  -e SPRING_DATASOURCE_USERNAME="$DB_USER" \
  -e SPRING_DATASOURCE_PASSWORD="$DB_PASSWORD" \
  -e SPRING_SQL_INIT_MODE=always \
  "$IMAGE"

echo "$IMAGE" > /opt/deploy/current_image
DEPLOY
chmod +x /opt/deploy/deploy.sh

# Wait for the Docker daemon, then do the first deploy.
until docker info >/dev/null 2>&1; do sleep 2; done
/opt/deploy/deploy.sh "${app_image}"
