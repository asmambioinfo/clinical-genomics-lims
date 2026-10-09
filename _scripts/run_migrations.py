import os
import sys
from core.database import DatabaseManager

def main():
    # Default to test environment if not specified
    env = sys.argv[1] if len(sys.argv) > 1 else 'test'
    
    if env not in ['test', 'prod']:
        print("Usage: python run_migrations.py [test|prod]")
        sys.exit(1)
        
    print(f"Initializing migration runner for environment: {env.upper()}")
    db = DatabaseManager(env=env)
    
    # 1. Ensure the tracking table exists natively in Azure SQL
    with db.get_cursor() as cursor:
        cursor.execute("""
            IF OBJECT_ID('migration_history', 'U') IS NULL
            BEGIN
                CREATE TABLE migration_history (
                    migration_id VARCHAR(255) PRIMARY KEY,
                    applied_at DATETIME DEFAULT GETDATE()
                )
            END
        """)
        
    # 2. Collect and sort all incremental delta scripts chronologically
    migration_dir = os.path.join(os.path.dirname(__file__), "../db/migrations")
    if not os.path.exists(migration_dir):
        print(f"Error: Migration directory '{migration_dir}' not found.")
        sys.exit(1)
        
    files = sorted([f for f in os.listdir(migration_dir) if f.endswith('.sql')])
    
    if not files:
        print("No migration files found in db/migrations/.")
        sys.exit(0)
        
    # 3. Read history and apply only missing deltas sequentially
    for file in files:
        with db.get_cursor() as cursor:
            cursor.execute("SELECT 1 FROM migration_history WHERE migration_id = %s", (file,))
            if cursor.fetchone():
                continue  # Skip already executed scripts
                
            print(f"Applying delta patch: {file}...")
            
            with open(os.path.join(migration_dir, file), 'r') as f:
                sql_script = f.read()
            
            # Execute migration logic and track it inside the transaction block
            try:
                cursor.execute(sql_script)
                cursor.execute("INSERT INTO migration_history (migration_id) VALUES (%s)", (file,))
                print(f"Successfully applied {file}.")
            except Exception as e:
                print(f"CRITICAL ERROR while executing {file}: {e}")
                print("Transaction halted. Database state preserved.")
                sys.exit(1)

if __name__ == "__main__":
    main()
