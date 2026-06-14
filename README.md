# Prism – Cloud Run Deployment Guide

This guide documents how to deploy the **Prism** AI Agent monitoring platform
to **Google Cloud Run** with a **Cloud SQL PostgreSQL** backend.

## Table of Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Environment Variables](#environment-variables-cloud-run)
- [Operations](#operations)
- [Teardown](#teardown)
- [Troubleshooting](#troubleshooting)
- [Test Suite Management](#test-suite-management)
  - [YAML Format](#test-suite-yaml-format)
  - [Assertion Types Reference](#assertion-types-reference)
  - [Method 1: UI Bulk Import](#method-1-bulk-import-via-prism-ui-recommended)
  - [Method 2: SQL Import via Proxy](#method-2-sql-import-via-cloud-sql-proxy-programmatic)
  - [Method 3: Python Client](#method-3-python-client-import-advanced)
  - [Writing Custom Test Cases](#writing-your-own-test-cases)
  - [Running an Evaluation](#running-an-evaluation)

## Architecture

```
┌─────────────┐      ┌────────────────────┐      ┌──────────────────────┐
│   Browser   │─────▶│  Cloud Run (Prism) │─────▶│  Cloud SQL (PG 15)   │
│             │ HTTPS│  Gunicorn + Dash   │ CSC  │  Instance: prism-db  │
└─────────────┘      │  Port 8080         │      │  Database: prism     │
                     └────────┬───────────┘      └──────────────────────┘
                              │
                     ┌────────▼───────────┐
                     │  Vertex AI / GenAI │
                     │  GDA API           │
                     └────────────────────┘
```

- **Cloud Run** hosts the Prism Dash web application via Gunicorn.
- **Cloud SQL** provides a managed PostgreSQL 15 database.
- The connection uses the **Cloud SQL Python Connector** (no SQL Auth Proxy sidecar needed).
- **Vertex AI / GenAI** powers the AI evaluation features.

## Prerequisites

| Tool | Minimum Version | Install |
|------|-----------------|---------|
| `gcloud` CLI | Latest | [Install Guide](https://cloud.google.com/sdk/docs/install) |
| `git` | 2.x | `brew install git` / `apt install git` |
| `openssl` | Any | Usually pre-installed |

### Required GCP IAM Permissions

The deploying user needs these roles (or equivalent):
- `roles/run.admin` – manage Cloud Run services
- `roles/cloudsql.admin` – create/manage Cloud SQL instances
- `roles/cloudbuild.builds.editor` – trigger Cloud Build
- `roles/iam.serviceAccountUser` – act as service account
- `roles/artifactregistry.writer` – push container images

## Quick Start

### 1. Clone this repository

```bash
cd /your/workspace
git clone <this-repo-url>
cd agent-eval
```

### 2. Configure environment (optional)

The script uses sensible defaults. Override via environment variables:

```bash
export PRISM_PROJECT_ID="lufeng-demo"          # GCP project ID
export PRISM_REGION="us-central1"              # Deployment region
export PRISM_SERVICE_NAME="prism"              # Cloud Run service name
export PRISM_SQL_INSTANCE="prism-db"           # Cloud SQL instance name
export PRISM_SQL_TIER="db-f1-micro"            # Cloud SQL machine tier
export PRISM_DB_NAME="prism"                   # Database name
export PRISM_DB_USER="prism"                   # Database user
export PRISM_DB_PASS=""                        # Auto-generated if empty
export PRISM_GDA_PROJECTS="lufeng-demo"        # GDA API project(s)
export PRISM_GENAI_CLIENT_PROJECT="lufeng-demo" # GenAI project
export PRISM_GENAI_CLIENT_LOCATION="us-central1"# GenAI location
```

### 3. Deploy

```bash
# Full deployment (creates all infrastructure + deploys)
./deploy.sh

# Or redeploy code changes only (skips infra creation)
./deploy.sh --deploy-only
```

### 4. Access the application

After deployment, the script prints the Cloud Run URL. Open it in your browser
to access the Prism dashboard.

## What the Script Does

### Full Deployment (`./deploy.sh`)

| Step | Description | Time |
|------|-------------|------|
| 1 | Enable required GCP APIs | ~30s |
| 2 | Create Cloud SQL PostgreSQL 15 instance | ~5-10 min |
| 3 | Create database user and `prism` database | ~10s |
| 4 | Grant IAM roles to Cloud Run service account | ~10s |
| 5 | Clone source, build Docker image, deploy to Cloud Run | ~3-5 min |
| 6 | Print deployment summary with URL | instant |

### Deploy-Only (`./deploy.sh --deploy-only`)

Skips steps 1-4, only rebuilds and redeploys the Cloud Run service. Useful for
code updates when infrastructure already exists.

## Environment Variables (Cloud Run)

These are automatically set by the deploy script on the Cloud Run service:

| Variable | Description | Default |
|----------|-------------|---------|
| `INSTANCE_CONNECTION_NAME` | Cloud SQL connection string (`project:region:instance`) | – |
| `DB_USER` | PostgreSQL user | `postgres` |
| `DB_PASS` | PostgreSQL password | – |
| `DB_NAME` | PostgreSQL database name | `prism` |
| `DB_IP_TYPE` | Cloud SQL IP type | `PUBLIC` |
| `PRISM_GDA_PROJECTS` | Comma-separated GDA project IDs | – |
| `PRISM_GENAI_CLIENT_PROJECT` | GCP project for GenAI API | – |
| `PRISM_GENAI_CLIENT_LOCATION` | GCP region for GenAI API | `us-central1` |
| `PRISM_DEBUG` | Enable debug mode | `false` |

## Operations

### View logs

```bash
gcloud run services logs read prism \
  --region=us-central1 \
  --project=lufeng-demo
```

### Redeploy after code changes

```bash
./deploy.sh --deploy-only
```

### Update environment variables

```bash
gcloud run services update prism \
  --region=us-central1 \
  --project=lufeng-demo \
  --update-env-vars="PRISM_DEBUG=true"
```

### Scale configuration

```bash
gcloud run services update prism \
  --region=us-central1 \
  --project=lufeng-demo \
  --min-instances=1 \
  --max-instances=5 \
  --memory=2Gi \
  --cpu=2
```

### Connect to Cloud SQL (for debugging)

```bash
gcloud sql connect prism-db \
  --user=prism \
  --database=prism \
  --project=lufeng-demo
```

### Run database migrations manually

If the application's auto-migration doesn't trigger:

```bash
# From the cloned repo directory
cd ca-agent-ops-prism
DATABASE_URL="postgresql://prism:<password>@<ip>/prism" \
  uv run alembic upgrade head
```

## Teardown

To delete **all** Prism resources (Cloud Run service + Cloud SQL instance):

```bash
./deploy.sh --teardown
```

> ⚠️ **Warning**: This permanently deletes the database and all data!

## Troubleshooting

### Cloud Run returns 5xx errors

1. Check logs: `gcloud run services logs read prism --region=us-central1`
2. Verify Cloud SQL instance is running:
   `gcloud sql instances describe prism-db --project=lufeng-demo`
3. Ensure the Cloud Run service account has `roles/cloudsql.client`

### Database connection failures

1. Verify `INSTANCE_CONNECTION_NAME` is correct:
   `lufeng-demo:us-central1:prism-db`
2. Ensure `DB_USER` and `DB_PASS` match the Cloud SQL user credentials
3. Check that the Cloud SQL instance has a public IP or VPC connector

### Build failures

1. Check Cloud Build logs:
   `gcloud builds list --project=lufeng-demo --limit=5`
2. Ensure `pyproject.toml` and `Dockerfile` are valid
3. Verify Artifact Registry repository exists:
   `gcloud artifacts repositories list --location=us-central1`

## Source Repository

- **Origin**: [looker-open-source/ca-demos-and-tools](https://github.com/looker-open-source/ca-demos-and-tools/tree/main/ca-agent-ops-prism)
- **Subdirectory**: `ca-agent-ops-prism`
- **License**: Apache 2.0

---

## Test Suite Management

Prism evaluates conversational analytics agents using **test suites** — collections
of test cases, each with a natural-language question and a set of assertions that
the agent's response must satisfy.

This section covers how to create test suites and bulk-import them into a deployed
Prism instance.

### Test Suite YAML Format

Test suites are defined in YAML as a list of test cases. Each test case has a
`question` and a list of `assertions`:

```yaml
- question: "What is the total number of active players?"
  assertions:
    - type: text-contains
      value: "active players"
    - type: data-check-row-count
      value: 1
    - type: duration-max-ms
      value: 30000
    - type: ai-judge
      value: "The response should contain a clear numeric count of active players."

- question: "Show the daily revenue trend for the past 7 days."
  assertions:
    - type: data-check-row-count
      value: 7
    - type: chart-check-type
      value: line
    - type: query-contains
      value: "ORDER BY"
```

### Assertion Types Reference

| Type | Description | `value` Parameter |
|------|-------------|-------------------|
| `text-contains` | Response text contains the specified string | String to search for |
| `query-contains` | Generated SQL query contains the specified string | SQL fragment (e.g., `GROUP BY`, `SUM`) |
| `data-check-row` | Validates specific row content in the result data | Row match criteria |
| `data-check-row-count` | Result set has the expected number of rows | Integer row count |
| `chart-check-type` | Agent returns the expected chart type | `line`, `bar`, `pie`, etc. |
| `duration-max-ms` | Response completes within the time limit | Max milliseconds (e.g., `30000`) |
| `ai-judge` | LLM-based evaluation of response quality | Natural-language rubric |
| `looker-query-match` | Looker query structure matches expected shape | Looker query spec |

### Example Test Suite

A pre-built test suite for the `gaming_demo` agent is included:

- **File**: [`gaming_demo_test_suite.yaml`](gaming_demo_test_suite.yaml)
- **Test cases**: 20 across 6 categories
- **Assertions**: 65 total

| Category | Tests | Focus |
|----------|-------|-------|
| Basic Metrics & KPIs | TC-01 – TC-04 | Active players, revenue, DAU, session duration |
| Segmentation & Filtering | TC-05 – TC-08 | Country breakdown, genre revenue, paying vs free |
| Trend & Time-Series | TC-09 – TC-12 | Daily revenue, WoW signups, MAU trends |
| Aggregations & Rankings | TC-13 – TC-16 | Top games, ARPU by platform, distributions |
| Complex Multi-Step | TC-17 – TC-18 | Tutorial conversion + LTV, churn analysis |
| Edge Cases & Guardrails | TC-19 – TC-20 | Destructive queries, gibberish input |

---

### Method 1: Bulk Import via Prism UI (Recommended)

The simplest way to import test cases is through the Prism web interface.

1. **Open Prism** in your browser: `https://prism-<project_number>.<region>.run.app`
2. Navigate to **Test Suites** → click **Create Test Suite**
3. Enter a **Name** (e.g., `gaming_demo_evaluation`) and **Description**
4. Click **Save** to create the empty suite
5. Click **Edit** on the suite, then use the **Bulk Import** feature
6. **Paste the YAML** content from `gaming_demo_test_suite.yaml` into the editor
7. Click **Import** — Prism parses the YAML and creates all test cases

> **Tip**: You can also use the AI-assisted import — paste free-form text
> describing your test cases and Prism will convert them to the structured format.

---

### Method 2: SQL Import via Cloud SQL Proxy (Programmatic)

For CI/CD or automated workflows, use the included script to generate SQL and
execute it against the Cloud SQL database.

#### Prerequisites

| Tool | Install |
|------|---------|
| `cloud-sql-proxy` | `gcloud components install cloud-sql-proxy` |
| `pg8000` (Python) | Already installed in the Prism venv |
| `python3` | System Python 3.10+ |

#### Step-by-Step

**1. Generate the SQL file**

```bash
python3 import_test_suite_sql.py > /tmp/import_test_suite.sql
```

This produces a single PostgreSQL `DO $$` block that creates the suite, all
test cases, and all assertions in one atomic transaction.

**2. Start the Cloud SQL Proxy**

```bash
cloud-sql-proxy "PROJECT_ID:REGION:INSTANCE_NAME" --port 15432 &
# Example:
cloud-sql-proxy "lufeng-demo:us-central1:prism-db" --port 15432 &
```

**3. Execute the SQL**

Option A — Using `psql` (if installed):

```bash
PGPASSWORD="<DB_PASSWORD>" psql \
  -h 127.0.0.1 -p 15432 \
  -U prism -d prism \
  -f /tmp/import_test_suite.sql
```

Option B — Using Python `pg8000` (from the Prism venv):

```bash
# Use the Prism virtual environment which already has pg8000
PRISM_DIR="/path/to/ca-agent-ops-prism"

$PRISM_DIR/.venv/bin/python3 -c "
import pg8000

conn = pg8000.connect(
    host='127.0.0.1',
    port=15432,
    user='prism',
    password='<DB_PASSWORD>',
    database='prism',
)
conn.autocommit = False
cursor = conn.cursor()

with open('/tmp/import_test_suite.sql') as f:
    sql = f.read()

try:
    cursor.execute(sql)
    conn.commit()
    print('✅ Test suite imported successfully!')
    
    # Verify
    cursor.execute(\"SELECT id, name FROM test_suites ORDER BY id DESC LIMIT 1\")
    row = cursor.fetchone()
    print(f'   Suite ID: {row[0]}, Name: {row[1]}')
except Exception as e:
    conn.rollback()
    print(f'❌ Error: {e}')
finally:
    cursor.close()
    conn.close()
"
```

**4. Stop the proxy**

```bash
kill %1  # or kill the proxy PID
```

**5. Verify in Prism UI**

Open `https://prism-<project_number>.<region>.run.app/test_suites` and confirm
the new suite appears with all 20 test cases.

#### One-Liner (Full Pipeline)

```bash
# Generate SQL, start proxy, import, stop proxy — all in one command
python3 import_test_suite_sql.py > /tmp/import_test_suite.sql && \
cloud-sql-proxy "lufeng-demo:us-central1:prism-db" --port 15432 & \
PROXY_PID=$! && sleep 5 && \
PGPASSWORD="<DB_PASSWORD>" psql -h 127.0.0.1 -p 15432 -U prism -d prism \
  -f /tmp/import_test_suite.sql && \
kill $PROXY_PID
```

---

### Method 3: Python Client Import (Advanced)

If running inside the same network as the Cloud SQL instance (e.g., on a GCE VM
or Cloud Shell), you can use the Prism client library directly:

```python
import sys, os
sys.path.insert(0, "/path/to/ca-agent-ops-prism/src")

os.environ.update({
    "INSTANCE_CONNECTION_NAME": "lufeng-demo:us-central1:prism-db",
    "DB_USER": "prism",
    "DB_PASS": "<DB_PASSWORD>",
    "DB_NAME": "prism",
    "DB_IP_TYPE": "PUBLIC",
    "PRISM_GDA_PROJECTS": "lufeng-demo",
    "PRISM_GENAI_CLIENT_PROJECT": "lufeng-demo",
    "PRISM_GENAI_CLIENT_LOCATION": "us-central1",
})

from prism.client import get_client

client = get_client()

# Create suite
suite = client.suites.create_suite(
    name="my_evaluation",
    description="Custom test suite",
)
print(f"Created suite: {suite.id}")

# Add test cases one by one
client.suites.add_example(
    suite_id=suite.id,
    question="What is the total revenue?",
    asserts=[
        {"type": "TEXT_CONTAINS", "params": {"value": "revenue"}},
        {"type": "AI_JUDGE", "params": {"value": "Must include a monetary value"}},
    ],
)
```

> **Note**: This method requires the Cloud SQL Python Connector to authenticate,
> which works best from within GCP (Cloud Shell, GCE, Cloud Run).

---

### Writing Your Own Test Cases

To create a custom test suite for a different agent:

1. **Copy the template**: `cp gaming_demo_test_suite.yaml my_agent_tests.yaml`
2. **Edit the YAML** — change questions to match your agent's domain
3. **Choose assertions** — pick from the [Assertion Types Reference](#assertion-types-reference)
4. **Import** — use any of the three methods above

**Best Practices**:

- Include **3-5 assertions per test case** for thorough coverage
- Always add a `duration-max-ms` assertion to catch performance regressions
- Use `ai-judge` for subjective quality checks with clear rubrics
- Include **edge cases** (invalid input, destructive queries) to test guardrails
- Organize tests into categories for easier analysis of results

### Running an Evaluation

After importing a test suite:

1. Go to the Prism UI → **Test Suites** → select your suite
2. Click **Run Evaluation**
3. Select the **agent** to evaluate (e.g., `gaming_demo`)
4. Click **Start** — Prism sends each question to the agent and evaluates responses
5. Review the results on the **Evaluation Results** page
