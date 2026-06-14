#!/usr/bin/env bash
# =============================================================================
# Prism Cloud Run Deployment Script
# =============================================================================
# Deploys the Prism AI Agent monitoring platform to Google Cloud Run with
# Cloud SQL PostgreSQL backend.
#
# Usage:
#   ./deploy.sh                   # Full deployment (create infra + deploy)
#   ./deploy.sh --deploy-only     # Skip infra creation, just build & deploy
#   ./deploy.sh --teardown        # Tear down all resources
#
# Prerequisites:
#   - gcloud CLI installed and authenticated
#   - git installed
#   - Sufficient IAM permissions in the target GCP project
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration – edit these to match your environment
# ---------------------------------------------------------------------------
PROJECT_ID="${PRISM_PROJECT_ID:-lufeng-demo}"
REGION="${PRISM_REGION:-us-central1}"
SERVICE_NAME="${PRISM_SERVICE_NAME:-prism}"
SQL_INSTANCE_NAME="${PRISM_SQL_INSTANCE:-prism-db}"
SQL_TIER="${PRISM_SQL_TIER:-db-f1-micro}"
DB_NAME="${PRISM_DB_NAME:-prism}"
DB_USER="${PRISM_DB_USER:-prism}"
DB_PASS="${PRISM_DB_PASS:-}"  # Auto-generated if empty
REPO_URL="${PRISM_REPO_URL:-https://github.com/looker-open-source/ca-demos-and-tools.git}"
REPO_SUBDIR="ca-agent-ops-prism"

# GCP-specific Prism config
PRISM_GDA_PROJECTS="${PRISM_GDA_PROJECTS:-$PROJECT_ID}"
PRISM_GENAI_CLIENT_PROJECT="${PRISM_GENAI_CLIENT_PROJECT:-$PROJECT_ID}"
PRISM_GENAI_CLIENT_LOCATION="${PRISM_GENAI_CLIENT_LOCATION:-$REGION}"

# ---------------------------------------------------------------------------
# Derived values
# ---------------------------------------------------------------------------
INSTANCE_CONNECTION_NAME="${PROJECT_ID}:${REGION}:${SQL_INSTANCE_NAME}"
CLONE_DIR="/tmp/prism-deploy-$(date +%s)"

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
generate_password() {
  openssl rand -base64 18 | tr -d '/+=' | head -c 24
}

check_prerequisites() {
  log_info "Checking prerequisites..."
  local missing=0
  for cmd in gcloud git openssl; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Required command '$cmd' not found."
      missing=1
    fi
  done
  if [ "$missing" -eq 1 ]; then
    exit 1
  fi
  log_success "All prerequisites met."
}

confirm_settings() {
  echo ""
  echo "==========================================="
  echo "  Prism Deployment Configuration"
  echo "==========================================="
  echo "  Project:          $PROJECT_ID"
  echo "  Region:           $REGION"
  echo "  Cloud Run Svc:    $SERVICE_NAME"
  echo "  SQL Instance:     $SQL_INSTANCE_NAME"
  echo "  SQL Tier:         $SQL_TIER"
  echo "  Database:         $DB_NAME"
  echo "  DB User:          $DB_USER"
  echo "  GDA Projects:     $PRISM_GDA_PROJECTS"
  echo "  GenAI Project:    $PRISM_GENAI_CLIENT_PROJECT"
  echo "  GenAI Location:   $PRISM_GENAI_CLIENT_LOCATION"
  echo "==========================================="
  echo ""
}

# ---------------------------------------------------------------------------
# Step 1: Enable Required APIs
# ---------------------------------------------------------------------------
enable_apis() {
  log_info "Enabling required GCP APIs..."
  gcloud services enable \
    run.googleapis.com \
    sqladmin.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    aiplatform.googleapis.com \
    cloudresourcemanager.googleapis.com \
    --project="$PROJECT_ID" \
    --quiet
  log_success "APIs enabled."
}

# ---------------------------------------------------------------------------
# Step 2: Create Cloud SQL Instance
# ---------------------------------------------------------------------------
create_cloud_sql() {
  log_info "Checking if Cloud SQL instance '$SQL_INSTANCE_NAME' exists..."
  if gcloud sql instances describe "$SQL_INSTANCE_NAME" \
       --project="$PROJECT_ID" &>/dev/null; then
    log_warn "Cloud SQL instance '$SQL_INSTANCE_NAME' already exists. Skipping creation."
    return
  fi

  log_info "Creating Cloud SQL PostgreSQL 15 instance '$SQL_INSTANCE_NAME'..."
  log_info "(This typically takes 5-10 minutes...)"
  gcloud sql instances create "$SQL_INSTANCE_NAME" \
    --database-version=POSTGRES_15 \
    --tier="$SQL_TIER" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --storage-size=10GB \
    --storage-auto-increase \
    --availability-type=zonal \
    --quiet
  log_success "Cloud SQL instance '$SQL_INSTANCE_NAME' created."
}

# ---------------------------------------------------------------------------
# Step 3: Create Database and User
# ---------------------------------------------------------------------------
setup_database() {
  # Generate password if not provided
  if [ -z "$DB_PASS" ]; then
    DB_PASS=$(generate_password)
    log_info "Generated DB password (save this): $DB_PASS"
  fi

  # Create user
  log_info "Creating database user '$DB_USER'..."
  if gcloud sql users list --instance="$SQL_INSTANCE_NAME" \
       --project="$PROJECT_ID" --format="value(name)" 2>/dev/null \
       | grep -q "^${DB_USER}$"; then
    log_warn "User '$DB_USER' already exists. Updating password..."
    gcloud sql users set-password "$DB_USER" \
      --instance="$SQL_INSTANCE_NAME" \
      --project="$PROJECT_ID" \
      --password="$DB_PASS" \
      --quiet
  else
    gcloud sql users create "$DB_USER" \
      --instance="$SQL_INSTANCE_NAME" \
      --project="$PROJECT_ID" \
      --password="$DB_PASS" \
      --quiet
  fi
  log_success "Database user '$DB_USER' ready."

  # Create database
  log_info "Creating database '$DB_NAME'..."
  if gcloud sql databases list --instance="$SQL_INSTANCE_NAME" \
       --project="$PROJECT_ID" --format="value(name)" 2>/dev/null \
       | grep -q "^${DB_NAME}$"; then
    log_warn "Database '$DB_NAME' already exists. Skipping."
  else
    gcloud sql databases create "$DB_NAME" \
      --instance="$SQL_INSTANCE_NAME" \
      --project="$PROJECT_ID" \
      --quiet
  fi
  log_success "Database '$DB_NAME' ready."
}

# ---------------------------------------------------------------------------
# Step 4: Grant IAM Permissions
# ---------------------------------------------------------------------------
grant_permissions() {
  log_info "Granting IAM permissions to Cloud Run service account..."

  # Get the default compute service account
  local project_number
  project_number=$(gcloud projects describe "$PROJECT_ID" \
    --format="value(projectNumber)")
  local sa="${project_number}-compute@developer.gserviceaccount.com"

  # Grant Cloud SQL Client role
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${sa}" \
    --role="roles/cloudsql.client" \
    --condition=None \
    --quiet &>/dev/null || true

  # Grant Vertex AI User role (for GenAI features)
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${sa}" \
    --role="roles/aiplatform.user" \
    --condition=None \
    --quiet &>/dev/null || true

  log_success "IAM permissions granted to $sa"
}

# ---------------------------------------------------------------------------
# Step 5: Clone Repo & Build/Deploy to Cloud Run
# ---------------------------------------------------------------------------
deploy_cloud_run() {
  log_info "Cloning repository..."
  rm -rf "$CLONE_DIR"
  git clone --filter=blob:none --sparse "$REPO_URL" "$CLONE_DIR" --quiet
  cd "$CLONE_DIR"
  git sparse-checkout set "$REPO_SUBDIR" --quiet
  cd "$REPO_SUBDIR"
  log_success "Repository cloned to $CLONE_DIR/$REPO_SUBDIR"

  log_info "Deploying to Cloud Run (building with Cloud Build)..."
  log_info "(This typically takes 3-5 minutes...)"

  gcloud run deploy "$SERVICE_NAME" \
    --source . \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --port=8080 \
    --memory=1Gi \
    --cpu=1 \
    --timeout=3600 \
    --min-instances=0 \
    --max-instances=3 \
    --add-cloudsql-instances="$INSTANCE_CONNECTION_NAME" \
    --set-env-vars="\
INSTANCE_CONNECTION_NAME=${INSTANCE_CONNECTION_NAME},\
DB_USER=${DB_USER},\
DB_PASS=${DB_PASS},\
DB_NAME=${DB_NAME},\
DB_IP_TYPE=PUBLIC,\
PRISM_GDA_PROJECTS=${PRISM_GDA_PROJECTS},\
PRISM_GENAI_CLIENT_PROJECT=${PRISM_GENAI_CLIENT_PROJECT},\
PRISM_GENAI_CLIENT_LOCATION=${PRISM_GENAI_CLIENT_LOCATION}" \
    --allow-unauthenticated \
    --quiet

  log_success "Cloud Run service '$SERVICE_NAME' deployed!"

  # Clean up clone
  rm -rf "$CLONE_DIR"
}

# ---------------------------------------------------------------------------
# Step 6: Print Summary
# ---------------------------------------------------------------------------
print_summary() {
  local url
  url=$(gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --format="value(status.url)" 2>/dev/null || echo "N/A")

  echo ""
  echo "==========================================="
  echo "  ✅ Deployment Complete!"
  echo "==========================================="
  echo "  Service URL:      $url"
  echo "  Cloud Run:        $SERVICE_NAME ($REGION)"
  echo "  Cloud SQL:        $SQL_INSTANCE_NAME ($REGION)"
  echo "  Database:         $DB_NAME"
  echo "  DB User:          $DB_USER"
  echo "  DB Password:      $DB_PASS"
  echo "==========================================="
  echo ""
  echo "  To view logs:"
  echo "    gcloud run services logs read $SERVICE_NAME --region=$REGION --project=$PROJECT_ID"
  echo ""
  echo "  To redeploy (code changes only):"
  echo "    ./deploy.sh --deploy-only"
  echo ""
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
teardown() {
  echo ""
  log_warn "⚠️  This will DELETE all Prism resources in project '$PROJECT_ID'!"
  read -rp "Are you sure? (yes/no): " confirm
  if [ "$confirm" != "yes" ]; then
    log_info "Cancelled."
    exit 0
  fi

  log_info "Deleting Cloud Run service '$SERVICE_NAME'..."
  gcloud run services delete "$SERVICE_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null || log_warn "Service not found."

  log_info "Deleting Cloud SQL instance '$SQL_INSTANCE_NAME'..."
  gcloud sql instances delete "$SQL_INSTANCE_NAME" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null || log_warn "Instance not found."

  log_success "Teardown complete."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local mode="${1:-full}"

  case "$mode" in
    --teardown)
      teardown
      exit 0
      ;;
    --deploy-only)
      check_prerequisites
      confirm_settings
      deploy_cloud_run
      print_summary
      ;;
    *)
      check_prerequisites
      confirm_settings
      enable_apis
      create_cloud_sql
      setup_database
      grant_permissions
      deploy_cloud_run
      print_summary
      ;;
  esac
}

main "$@"
