#!/usr/bin/env bash
#
# Lakebase Branch Manager
# ========================
# Creates (or reuses) a Lakebase dev branch tied to the current git branch
# and writes connection credentials to .env.lakebase.
#
# Usage:
#   ./scripts/lakebase-branch.sh [--force] [--refresh-only]
#
# Options:
#   --force          Delete and recreate the branch
#   --refresh-only   Only regenerate credentials (skip branch creation)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/lakebase.config"
ENV_FILE="$PROJECT_ROOT/.env.lakebase"
BRANCH_TTL="21600s"  # 6 hours

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

FORCE=false
REFRESH_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)        FORCE=true; shift ;;
        --refresh-only) REFRESH_ONLY=true; shift ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}lakebase.config not found. Run 'make lakebase-init' first.${NC}"
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ -z "${LAKEBASE_PROJECT_ID:-}" ]]; then
    echo -e "${RED}LAKEBASE_PROJECT_ID is empty. Run 'make lakebase-init' first.${NC}"
    exit 1
fi

PROJECT_PATH="projects/${LAKEBASE_PROJECT_NAME}"

PROFILE_FLAG=""
if [[ -n "${LAKEBASE_PROFILE:-}" && "$LAKEBASE_PROFILE" != "DEFAULT" ]]; then
    PROFILE_FLAG="-p $LAKEBASE_PROFILE"
fi

echo -e "${BLUE}Lakebase Branch Manager${NC}"
echo "=================================="

# ---------------------------------------------------------------------------
# Check requirements
# ---------------------------------------------------------------------------

check_requirements() {
    echo -e "\n${YELLOW}Checking requirements...${NC}"

    for tool in databricks jq python3; do
        if ! command -v "$tool" &>/dev/null; then
            echo -e "${RED}${tool} not found.${NC}"
            exit 1
        fi
    done

    if ! databricks postgres --help &>/dev/null; then
        echo -e "${RED}Databricks CLI postgres commands not available. Upgrade to >= 0.287.0${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}All requirements met${NC}"
}

# ---------------------------------------------------------------------------
# Derive branch name from git context
# ---------------------------------------------------------------------------

get_branch_name() {
    echo -e "\n${YELLOW}Deriving branch name...${NC}"

    GIT_USER=$(git config user.name 2>/dev/null || echo "unknown")
    GIT_USER=$(echo "$GIT_USER" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')

    GIT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
    if [[ -z "$GIT_BRANCH" ]]; then
        echo -e "${RED}Not on a git branch (detached HEAD). Check out a branch first.${NC}"
        exit 1
    fi

    LAKEBASE_BRANCH="dev-${GIT_USER}-${GIT_BRANCH}"
    LAKEBASE_BRANCH_PATH="${PROJECT_PATH}/branches/${LAKEBASE_BRANCH}"

    echo -e "  Git user:     ${GREEN}${GIT_USER}${NC}"
    echo -e "  Git branch:   ${GREEN}${GIT_BRANCH}${NC}"
    echo -e "  Lakebase branch: ${GREEN}${LAKEBASE_BRANCH}${NC}"
}

# ---------------------------------------------------------------------------
# Create or reuse branch
# ---------------------------------------------------------------------------

ensure_branch() {
    if [[ "$REFRESH_ONLY" == "true" ]]; then
        echo -e "\n${YELLOW}Refresh-only mode, skipping branch creation${NC}"
        return
    fi

    echo -e "\n${YELLOW}Checking if branch exists...${NC}"

    if databricks postgres get-branch "$LAKEBASE_BRANCH_PATH" $PROFILE_FLAG -o json &>/dev/null; then
        if [[ "$FORCE" == "true" ]]; then
            echo -e "  Branch exists. ${YELLOW}Force mode: deleting and recreating.${NC}"
            databricks postgres delete-branch "$LAKEBASE_BRANCH_PATH" $PROFILE_FLAG --no-wait 2>/dev/null || true
            sleep 5
        else
            echo -e "  ${GREEN}Branch already exists, reusing${NC}"
            return
        fi
    fi

    echo -e "\n${YELLOW}Creating branch from ${LAKEBASE_PARENT_BRANCH}...${NC}"

    SOURCE_BRANCH="${PROJECT_PATH}/branches/${LAKEBASE_PARENT_BRANCH}"

    databricks postgres create-branch "$PROJECT_PATH" "$LAKEBASE_BRANCH" \
        --json '{"spec": {"source_branch": "'"${SOURCE_BRANCH}"'", "ttl": "'"${BRANCH_TTL}"'"}}' \
        $PROFILE_FLAG \
        -o json >/dev/null 2>&1 || {
        echo -e "${RED}Failed to create branch${NC}"
        exit 1
    }

    echo -e "  ${GREEN}Branch created${NC}"
}

# ---------------------------------------------------------------------------
# Get or create endpoint, wait until ACTIVE
# ---------------------------------------------------------------------------

ensure_endpoint() {
    echo -e "\n${YELLOW}Setting up endpoint...${NC}"

    MAX_ATTEMPTS=60
    ATTEMPT=0

    while true; do
        ATTEMPT=$((ATTEMPT + 1))
        ENDPOINTS_JSON=$(databricks postgres list-endpoints "$LAKEBASE_BRANCH_PATH" $PROFILE_FLAG -o json 2>/dev/null || echo "[]")
        ENDPOINT_COUNT=$(echo "$ENDPOINTS_JSON" | jq 'length')

        if [[ "$ENDPOINT_COUNT" -gt 0 ]]; then
            ENDPOINT_NAME=$(echo "$ENDPOINTS_JSON" | jq -r '.[0].name')
            ENDPOINT_HOST=$(echo "$ENDPOINTS_JSON" | jq -r '.[0].status.hosts.host')
            echo -e "  ${GREEN}Endpoint ACTIVE: ${ENDPOINT_HOST}${NC}"
            return
            echo -e "  Attempt ${ATTEMPT}/${MAX_ATTEMPTS} — state: ${STATE:-unknown}..."
        else
            # No endpoint yet — create one
            echo -e "  Creating endpoint..."
            databricks postgres create-endpoint "$LAKEBASE_BRANCH_PATH" "dev" \
                --json '{"spec": {"endpoint_type": "ENDPOINT_TYPE_READ_WRITE", "autoscaling_limit_min_cu": 0.5, "autoscaling_limit_max_cu": 2.0}}' \
                $PROFILE_FLAG \
                -o json >/dev/null 2>&1 || true
            echo -e "  Waiting for endpoint to become ACTIVE..."
        fi

        if [[ $ATTEMPT -ge $MAX_ATTEMPTS ]]; then
            echo -e "${RED}Timed out waiting for endpoint${NC}"
            exit 1
        fi

        sleep 5
    done
}

# ---------------------------------------------------------------------------
# Generate credentials and write .env.lakebase
# ---------------------------------------------------------------------------

generate_credentials() {
    echo -e "\n${YELLOW}Generating credentials...${NC}"

    CREDS_JSON=$(databricks postgres generate-database-credential "$ENDPOINT_NAME" $PROFILE_FLAG -o json 2>&1) || {
        echo -e "${RED}Failed to generate credentials${NC}"
        echo "$CREDS_JSON"
        exit 1
    }

    DB_USER=$(databricks current-user me $PROFILE_FLAG -o json | jq -r '.userName')
    DB_PASSWORD=$(echo "$CREDS_JSON" | jq -r '.token')
    CREDS_EXPIRE=$(echo "$CREDS_JSON" | jq -r '.expire_time')

    echo -e "  ${GREEN}Credentials generated${NC}"
    echo -e "  Token expires: ${YELLOW}${CREDS_EXPIRE}${NC}"
}

write_env_file() {
    echo -e "\n${YELLOW}Writing .env.lakebase...${NC}"

    DATABASE_URL=$(python3 -c "
from urllib.parse import quote_plus
user = quote_plus('$DB_USER')
password = quote_plus('$DB_PASSWORD')
print(f'postgresql://{user}:{password}@${ENDPOINT_HOST}:5432/${LAKEBASE_DATABASE}?sslmode=require')
")

    cat > "$ENV_FILE" <<EOF
# Generated by scripts/lakebase-branch.sh — do not commit
# Branch: ${LAKEBASE_BRANCH}
# Created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Token expires: ${CREDS_EXPIRE}

DATABASE_URL=${DATABASE_URL}
DB_SOURCE=lakebase/${LAKEBASE_BRANCH}
LAKEBASE_BRANCH_PATH=${LAKEBASE_BRANCH_PATH}
EOF

    echo -e "  ${GREEN}.env.lakebase written${NC}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    check_requirements
    get_branch_name
    ensure_branch
    ensure_endpoint
    generate_credentials
    write_env_file

    echo -e "\n${GREEN}==================================${NC}"
    echo -e "${GREEN}Lakebase branch ready!${NC}"
    echo -e "${GREEN}==================================${NC}"
    echo -e "\nBranch:   ${BLUE}${LAKEBASE_BRANCH}${NC}"
    echo -e "Host:     ${BLUE}${ENDPOINT_HOST}${NC}"
    echo -e "Expires:  ${YELLOW}${CREDS_EXPIRE}${NC}"
}

main
