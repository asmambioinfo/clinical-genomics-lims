# test_conn.py
from _scripts.core.database import DatabaseManager

print("🔄 Attempting to connect to Azure SQL via pymssql...")
try:
    # 1. Initialize our custom database manager tool
    db = DatabaseManager()
    
    # 2. Ask it to build the secure channel
    conn = db.get_connection()
    cursor = conn.cursor()
    
    # 3. Query Azure for the current database name to verify alignment
    cursor.execute("SELECT DB_NAME();")
    row = cursor.fetchone()
    
    print("\n🎉 CONNECTION SUCCESSFUL!")
    print(f"🌍 Connected to Database Instance: {row[0]}")
    
    conn.close()
except Exception as e:
    print(f"\n❌ Connection failed.")
    print(f"🔍 Error details: {e}")
