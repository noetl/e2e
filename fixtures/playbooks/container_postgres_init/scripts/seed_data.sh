#!/bin/bash
set -euo pipefail

# PGPORT is intentionally NOT passed as a container env var by the fixture:
# the NoETL server coerces pure-numeric env string values to JSON numbers,
# which the container tool rejects (ContainerEnvVar.value is a String).
# Default it here so libpq/psql target 5432 (the in-cluster Postgres port).
# See noetl/ai-meta#186.
export PGPORT="${PGPORT:-5432}"

# seed_data.sh - Seed test data via container
# This script demonstrates data population with SQL scripts

echo "==================================================="
echo "NoETL Container Job: Data Seeding"
echo "==================================================="
echo "Execution ID: ${EXECUTION_ID:-unknown}"
echo "Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
echo "Schema: ${SCHEMA_NAME}"
echo "==================================================="

# Verify required environment variables
required_vars=("PGHOST" "PGPORT" "PGDATABASE" "PGUSER" "PGPASSWORD" "SCHEMA_NAME")
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: Required environment variable $var is not set"
        exit 1
    fi
done

# Execute data seeding SQL
echo "Executing seed_data.sql..."
if [ -f "/workspace/seed_data.sql" ]; then
    psql -v ON_ERROR_STOP=1 -f /workspace/seed_data.sql
    echo "✓ Data seeded successfully"
else
    echo "ERROR: seed_data.sql not found"
    exit 1
fi

# Log execution
echo ""
echo "Logging execution..."
psql -v ON_ERROR_STOP=1 <<-EOSQL
    INSERT INTO container_test.execution_log (execution_id, step_name, status, message)
    VALUES ('${EXECUTION_ID}', 'seed_data', 'success', 'Data seeded via container job');
EOSQL

# Report row counts
echo ""
echo "Data summary:"
psql -c "
    SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM container_test.customers
    UNION ALL
    SELECT 'orders' AS table_name, COUNT(*) AS row_count FROM container_test.orders
    UNION ALL
    SELECT 'products' AS table_name, COUNT(*) AS row_count FROM container_test.products
    UNION ALL
    SELECT 'order_items' AS table_name, COUNT(*) AS row_count FROM container_test.order_items
    ORDER BY table_name;
"

# Show sample data
echo ""
echo "Sample customers (first 3):"
psql -c "SELECT * FROM ${SCHEMA_NAME}.customers LIMIT 3;"

echo ""
echo "Sample orders (first 3):"
psql -c "SELECT * FROM ${SCHEMA_NAME}.orders LIMIT 3;"

echo ""
echo "==================================================="
echo "Data seeding complete!"
echo "==================================================="
exit 0
