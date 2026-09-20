# Overview

This repository provisions, ships, and monitors a containerised web application
(Spring PetClinic) on AWS, end to end:

##Part_1 - Infra: Create a VPC, an EC2 instance for application, RDS postgresql db, an ALB, SG and IAM 

### Prerequisite create a S3 bucket for tfbackend enable versioning also create dynamodb table with Attribute= LockID

```
cd infra/terraform
terraform init -backend-config=backend.tfbackend

terraform plan

terraform apply

terraform output app_url          # open this to reach the app
```
Key outpur: app_url, alb_dns_name, app_instance_id (the CD action use this via SSM)

###Part_2 - Deployment (CI/CD)

Two GitHub Actions workflows in .github/workflows/:

- **ci.yml** runs on pull requests to main: unit + integration tests
  (`mvn verify`) and a Trivy dependency scan.
- **cd.yml** runs on merge to main: test, build the image, Trivy image scan,
  push to Docker Hub (tagged with the commit SHA and `latest`), deploy to
  staging, then deploy to production behind a manual approval gate.

Deployment does not use SSH. The pipeline finds the instance by its Name tag,
then runs `sudo /opt/deploy/deploy.sh <image>` on it via SSM Run Command. That
script (written onto the host by Terraform user-data) pulls the image and
restarts the container, reading the DB password from Secrets Manager.

The manual aproval is a Github ENV (production) with a required reviewer - the pipeline pause there ubntil approved

Failure notifications are
sent by email from an explicit workflow step (Gmail SMTP).

Secret and varible required for CI/CD

Secrets - AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, DOCKERHUB_TOKEN, DOCKERHUB_USERNAME, MAIL_PASSWORD, MAIL_TO, MAIL_USERNAME

Variables - APP_INSTANCE_TAG, AWS_REGION, IMAGE_NAME, PROD_INSTANCE_TAG


### Part 3- Monitoring & Logging 

A container stack (monitoring/docker-compose.monitoring.yml) runs on the app
host and provides:

- **Infrastructure metrics** (CPU, memory, disk) via node-exporter
- **Container metrics** via cAdvisor
- **Application metrics** (request rate, error rate, latency) via Spring
  Actuator + Micrometer at /actuator/prometheus
- **Database metrics** via postgres-exporter against RDS
- **Centralised logs** (application + system) via Loki + Promtail

Grafana ships two provisioned dashboards — *Infrastructure & Application* and
*Logs & Database*. Grafana and Prometheus bind to 127.0.0.1 on the host and
are reached through an SSM port-forward tunnel, so nothing is exposed to the
internet and no inbound security-group rules are added.

Steps to step up 

The app host has no inbound SSH, so push the `monitoring/` folder over SSM. The
simplest route is to pull it from your GitHub repo on the box:

```bash
# open a shell on the box
aws ssm start-session --target <INSTANCE_ID>

# on the box:
sudo mkdir -p /opt/monitoring && cd /opt/monitoring
sudo git clone https://github.com/<you>/<repo>.git .
cd monitoring
```

(If the repo is private, use a read-only deploy token, or `aws s3 cp` the folder
via a bucket. For the assessment a public repo or token is fine.)

## Step 2 — Create `monitoring.env` (holds the DB password)

`postgres-exporter` needs the DB connection string, and Grafana needs an admin
password. Fetch the DB password from Secrets Manager and write the env file
(this file is git-ignored and never committed):

```bash
DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id devops-assessment-staging-db-password \
  --region us-east-1 --query SecretString --output text)

RDS_HOST=$(grep DB_HOST /opt/deploy/app.env | cut -d= -f2)

cat > monitoring.env <<EOF
DATA_SOURCE_NAME=postgresql://petclinic:${DB_PASSWORD}@${RDS_HOST}:5432/petclinic?sslmode=require
GF_SECURITY_ADMIN_PASSWORD=$(openssl rand -base64 16)
EOF

echo "Grafana admin password:"; grep GF_SECURITY_ADMIN_PASSWORD monitoring.env
```

Note the printed Grafana password — you'll log in with `admin` / that value.

## Step 3 — Start the stack

```bash
sudo docker compose -f docker-compose.monitoring.yml up -d
sudo docker compose -f docker-compose.monitoring.yml ps    # all should be "running"
```

First start pulls images (a few minutes). Exit the SSM shell when done (`exit`).

## Step 4 — Verify Prometheus is scraping everything

Still on the box (or after tunneling), check targets are UP:

```bash
curl -s http://localhost:9090/api/v1/targets | \
  grep -o '"job":"[^"]*","[^}]*"health":"[^"]*"'
```

You want `node`, `cadvisor`, `petclinic`, `postgres`, `prometheus` all `up`. If
`petclinic` is `down`, the app isn't exposing `/actuator/prometheus` (Step in
prerequisites); if `postgres` is `down`, check `monitoring.env`.

## Step 5 — Reach Grafana over an SSM tunnel (from your laptop)

```bash
aws ssm start-session --target <INSTANCE_ID> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
```

Leave that running, then open **http://localhost:3000** in your browser. Log in
with `admin` and the password from Step 2. Both dashboards are already loaded
(Dashboards → Browse): **Infrastructure & Application** and **Logs & Database**.

To reach Prometheus directly, do the same with `"portNumber":["9090"]`.


## Part 4 — Best practices

### Security considerations

- **No SSH.** Administration is via SSM Session Manager — no open port 22, no key
  pairs to leak.
- **Tiered security groups.** ALB then app then RDS, each tier reachable only
  from the tier in front of it, referenced by security group rather than by IP so
  the rules survive instance replacement.
- **Private, encrypted database.** RDS is `publicly_accessible = false` and
  storage-encrypted; it has no internet route.
- **Least-privilege IAM.** The app host role can read only the one DB secret; the
  CI user can only describe instances and run SSM commands.
- **Grafana is never public** — reached only through the SSM tunnel.


### Secret management (implemented)

The database password is generated by Terraform (`random_password`), stored in
**AWS Secrets Manager**, and read at runtime by the app host through an IAM role
scoped to that single secret ARN. It is never committed, baked into the image, or
placed in the boot script. The monitoring stack's copy of the credentials is
generated on the host from the same secret and is git-ignored.

### Backup strategy (implemented)

RDS **automated backups** are enabled with `backup_retention_period = 7`, giving
daily snapshots and point-in-time recovery within the window. Restore is a
point-in-time restore into a new instance. Storage is encrypted at rest.

---

## Approach & key decisions

- **Match the app to the stack.** PetClinic is a Spring/Java app, matching the
  reference codebase, and is a single server-rendered artifact — one image serves
  both the "frontend" (behind the ALB) and the backend, with a PostgreSQL
  profile for RDS.
- **EC2 + SSM deploys, not orchestration.** For one container on a small budget,
  a single EC2 host deployed to over SSM is cheaper and simpler than ECS/EKS, and
  mirrors the SSM-based deployment pattern in the reference pipelines.
- **Ephemeral infrastructure, tag-based deploys.** The environment is torn down
  between sessions, so the pipeline discovers the instance by tag at deploy time
  rather than hard-coding an instance ID that would go stale on every apply.
- **Immutable image tags.** Images are tagged with the commit SHA so every deploy
  is traceable to an exact commit and is rollback-friendly.
- **Security-first defaults.** No SSH, IMDSv2, tiered SGs, private DB, secrets in
  Secrets Manager, monitoring UIs private behind SSM.

### Noted production improvements

- Move the app host into a private subnet behind a NAT instance/gateway; keep the
  ALB as the only public resource.
- Add an HTTPS listener (ACM certificate) on the ALB.
- Replace the CI user's long-lived AWS keys with GitHub OIDC federation.
- Bind Actuator to a separate management port not exposed via the ALB.
- Run monitoring on separate infrastructure (or Amazon Managed Prometheus/
  Grafana) so it survives an app-host failure; add Mimir (long-term metrics) and
  Tempo (tracing).
- Gate the pipeline on Trivy severity (`exit-code 1`) once base-image/dependency
  versions are bumped.

---

## Challenges faced and resolutions

- **SSM node would not register.** On Amazon Linux 2023 the instance ran with
  correct IAM, public IP and internet route, but never appeared in
  ssm describe-instance-information, so send-command failed with
  InvalidInstanceId. Switched the AMI to Ubuntu 24.04 and, because Ubuntu ships
  the SSM agent as a **snap**, explicitly enabled/started `amazon-ssm-agent` in
  user-data before the package update. The node then registered reliably.

- **Ubuntu has no AWS CLI.** Unlike Amazon Linux, Ubuntu does not preinstall the
  AWS CLI, which the on-host `deploy.sh` needs to read the DB secret. Added a
  `snap install aws-cli` step and put `/snap/bin` on PATH inside the deploy
  script (SSM Run Command uses a minimal PATH that omits it).

- **Docker image architecture.** An image built on Apple Silicon defaults to
  arm64 and crash-loops on the x86 EC2 host, leaving the ALB target unhealthy.
  Fixed by building with `--platform linux/amd64`.

- **PetClinic integration tests in CI.** mvn verify triggered
  PostgresIntegrationTests, which expects a Docker-Compose-managed database.
  Excluded that one class from CI (-Dtest='!*IntegrationTests'); DB
  integration is validated instead by the staging deploy against real RDS.

- **Empty image tag in the deploy job (the hardest one).** The deploy step kept
  receiving an empty image reference. Root cause: the Docker Hub username was a
  GitHub **secret** and also formed part of the image name, so GitHub's
  secret-masking refused to pass the job output containing it (Skip output
  'image' since it may contain secret). Resolved by constructing the image
  reference in the deploy job from non-secret values (a repository variable plus
  the commit SHA) rather than reading it from a masked job output.

- **Shell/Terraform escaping in the templated deploy script.** Under `set -u`,
  `$1` was unbound when the script ran without an argument; and `${1:-}` collided
  with Terraform's `templatefile()` interpolation. Handled by making the argument
  optional and escaping the brace form as `$${1:-}` so Terraform emits literal
  shell.

- **Session Manager plugin.** `aws ssm start-session` failed with
  "SessionManagerPlugin not found" — it is a separate install from the AWS CLI.
  Verified deploys with `aws ssm send-command` (no plugin required) and installed
  the plugin for interactive access and Grafana port-forwarding.

- **Application metrics endpoint missing.** PetClinic includes Actuator but not
  the Micrometer Prometheus registry, so `/actuator/prometheus` did not exist.
  Added `micrometer-registry-prometheus` and exposed the endpoint
  (`management.endpoints.web.exposure.include=health,info,prometheus`), shipped
  through the CI/CD pipeline.
