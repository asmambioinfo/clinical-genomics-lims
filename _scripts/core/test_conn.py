# _scripts/core/test_conn.py
#
# Run two ways:
#   CI / pytest gate:    python3 -m pytest _scripts/core/test_conn.py -v
#   Manual diagnostic:   python3 _scripts/core/test_conn.py [test|prod]

import sys
from _scripts.core.database import DatabaseManager


def test_database_connection():
    """Confirms the test database is reachable and .env.test has valid
    credentials. This is what CI runs (see .github/workflows/deploy.yml)."""
    db = DatabaseManager(env="test")
    conn = db.get_connection()
    conn.close()


if __name__ == "__main__":
    env = sys.argv[1] if len(sys.argv) > 1 else "test"
    print(f"Attempting to connect to Azure SQL ({env}) via pymssql...")
    try:
        db = DatabaseManager(env=env)
        conn = db.get_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT DB_NAME();")
        row = cursor.fetchone()
        print("Connection successful.")
        print(f"Connected to database instance: {row[0]}")
        conn.close()
    except Exception as e:
        print("Connection failed.")
        print(f"Error details: {e}")
        sys.exit(1)