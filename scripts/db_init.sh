#!/usr/bin/env bash
#
# Lakebase One-Time Initialization
# =================================
# Creates the Lakebase project, waits for the production endpoint,
# creates the application database, and writes the project ID into lakebase.config.
#
# Usage:  ./scripts/db_init.sh
#
# This script is idempotent — safe to run multiple times.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/lakebase.config"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}lakebase.config not found${NC}"
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

PROFILE_FLAG=""
if [[ -n "${LAKEBASE_PROFILE:-}" && "$LAKEBASE_PROFILE" != "DEFAULT" ]]; then
    PROFILE_FLAG="-p $LAKEBASE_PROFILE"
fi

# ---------------------------------------------------------------------------
# Check requirements
# ---------------------------------------------------------------------------

check_requirements() {
    echo -e "${BLUE}Lakebase Project Initialization${NC}"
    echo "=================================="
    echo -e "\n${YELLOW}Checking requirements...${NC}"

    if ! command -v databricks &>/dev/null; then
        echo -e "${RED}Databricks CLI not found. Install it first.${NC}"
        exit 1
    fi

    CLI_VERSION=$(databricks version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
    echo -e "  Databricks CLI: ${GREEN}${CLI_VERSION}${NC}"

    if ! databricks postgres --help &>/dev/null; then
        echo -e "${RED}Databricks CLI postgres commands not available. Upgrade to >= 0.287.0${NC}"
        exit 1
    fi

    for tool in jq psql; do
        if ! command -v "$tool" &>/dev/null; then
            echo -e "${RED}${tool} not found. Install it first.${NC}"
            exit 1
        fi
        echo -e "  ${tool}: ${GREEN}installed${NC}"
    done
}

# ---------------------------------------------------------------------------
# Write a config value back to lakebase.config
# ---------------------------------------------------------------------------

write_config() {
    local key="$1"
    local value="$2"
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s|^${key}=.*|${key}=${value}|" "$CONFIG_FILE"
    else
        sed -i "s|^${key}=.*|${key}=${value}|" "$CONFIG_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Create or detect project
# ---------------------------------------------------------------------------

ensure_project() {
    echo -e "\n${YELLOW}Checking for existing project...${NC}"

    if [[ -n "${LAKEBASE_PROJECT_NAME:-}" ]]; then
        PROJECT_PATH="projects/${LAKEBASE_PROJECT_NAME}"
        PROJECT_JSON=$(databricks postgres get-project "$PROJECT_PATH" $PROFILE_FLAG -o json 2>/dev/null) || PROJECT_JSON=""
        if [[ -n "$PROJECT_JSON" ]]; then
            LAKEBASE_PROJECT_ID=$(echo "$PROJECT_JSON" | jq -r '.uid')
            write_config "LAKEBASE_PROJECT_ID" "$LAKEBASE_PROJECT_ID"
            echo -e "  ${GREEN}Project already exists: ${LAKEBASE_PROJECT_NAME}${NC}"
            echo -e "  ${GREEN}Project ID written to lakebase.config${NC}"
            return
        fi
        echo -e "  ${YELLOW}Configured project ID not found, will create a new one${NC}"
    fi

    echo -e "\n${YELLOW}Creating project '${LAKEBASE_PROJECT_NAME}'...${NC}"

    CREATE_RESULT=$(databricks postgres create-project "$LAKEBASE_PROJECT_NAME" \
        --json '{"spec": {"display_name": "Lakebase Docker Compose Demo"}}' \
        $PROFILE_FLAG \
        -o json 2>&1) || {
        echo -e "${RED}Failed to create project${NC}"
        echo "$CREATE_RESULT"
        exit 1
    }

    LAKEBASE_PROJECT_ID=$(echo "$CREATE_RESULT" | jq -r '.uid')
    echo -e "  ${GREEN}Project created: ${LAKEBASE_PROJECT_NAME}${NC}"

    write_config "LAKEBASE_PROJECT_ID" "$LAKEBASE_PROJECT_ID"
    echo -e "  ${GREEN}Project ID written to lakebase.config${NC}"
}

# ---------------------------------------------------------------------------
# Wait for production endpoint
# ---------------------------------------------------------------------------

wait_for_endpoint() {
    echo -e "\n${YELLOW}Waiting for production endpoint to become ACTIVE...${NC}"

    PROJECT_PATH="projects/${LAKEBASE_PROJECT_NAME}"
    BRANCH_PATH="${PROJECT_PATH}/branches/${LAKEBASE_PARENT_BRANCH}"
    MAX_ATTEMPTS=60
    ATTEMPT=0

    while true; do
        ATTEMPT=$((ATTEMPT + 1))
        ENDPOINTS_JSON=$(databricks postgres list-endpoints "$BRANCH_PATH" $PROFILE_FLAG -o json 2>/dev/null || echo "[]")
        STATE=$(echo "$ENDPOINTS_JSON" | jq -r '.[0].status.current_state // empty')

        if [[ "$STATE" == "ACTIVE" ]]; then
            ENDPOINT_HOST=$(echo "$ENDPOINTS_JSON" | jq -r '.[0].status.hosts.host')
            ENDPOINT_NAME=$(echo "$ENDPOINTS_JSON" | jq -r '.[0].name')
            echo -e "  ${GREEN}Endpoint ACTIVE: ${ENDPOINT_HOST}${NC}"
            return
        fi

        if [[ $ATTEMPT -ge $MAX_ATTEMPTS ]]; then
            echo -e "${RED}Timed out waiting for endpoint (${MAX_ATTEMPTS} attempts)${NC}"
            exit 1
        fi

        echo -e "  Attempt ${ATTEMPT}/${MAX_ATTEMPTS} — state: ${STATE:-pending}..."
        sleep 5
    done
}

# ---------------------------------------------------------------------------
# Create database
# ---------------------------------------------------------------------------

create_database() {
    echo -e "\n${YELLOW}Ensuring database '${LAKEBASE_DATABASE}' exists...${NC}"

    # Generate credentials
    CREDS_JSON=$(databricks postgres generate-database-credential "$ENDPOINT_NAME" $PROFILE_FLAG -o json 2>&1) || {
        echo -e "${RED}Failed to generate credentials${NC}"
        echo "$CREDS_JSON"
        exit 1
    }

    DB_USER=$(databricks current-user me $PROFILE_FLAG -o json | jq -r '.userName')
    DB_PASSWORD=$(echo "$CREDS_JSON" | jq -r '.token')

    # Check if database already exists
    DB_EXISTS=$(PGPASSWORD="$DB_PASSWORD" psql \
        "host=$ENDPOINT_HOST port=5432 dbname=postgres user=$DB_USER sslmode=require" \
        -tAc "SELECT 1 FROM pg_database WHERE datname='${LAKEBASE_DATABASE}'" 2>/dev/null || echo "")
    echo -e "  Debug: DB_EXISTS='$DB_EXISTS'"

    if [[ "$DB_EXISTS" == "1" ]]; then
        echo -e "  ${GREEN}Database '${LAKEBASE_DATABASE}' already exists${NC}"
    else
        PGPASSWORD="$DB_PASSWORD" psql \
            "host=$ENDPOINT_HOST port=5432 dbname=postgres user=$DB_USER sslmode=require" \
            -c "CREATE DATABASE ${LAKEBASE_DATABASE};" 2>&1 || {
            echo -e "${RED}Failed to create database${NC}"
            exit 1
        }
        echo -e "  ${GREEN}Database '${LAKEBASE_DATABASE}' created${NC}"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    check_requirements
    ensure_project
    wait_for_endpoint
    create_database

    echo -e "\n${GREEN}==================================${NC}"
    echo -e "${GREEN}Lakebase initialization complete!${NC}"
    echo -e "${GREEN}==================================${NC}"
    echo -e "\nProject ID: ${BLUE}${LAKEBASE_PROJECT_ID}${NC}"
    echo -e "Database:   ${BLUE}${LAKEBASE_DATABASE}${NC}"
    echo -e "Endpoint:   ${BLUE}${ENDPOINT_HOST}${NC}"
    echo -e "\nNext step:  ${YELLOW}make dev-lakebase${NC}"
}

main
