# _scripts/core/database.py
import os
import pymssql
from dotenv import load_dotenv

class DatabaseManager:
    def __init__(self):
        # Read the hidden credentials from your .env.test file
        load_dotenv(".env.test")
        
        self.server = os.getenv("DB_SERVER")
        self.database = os.getenv("DB_DATABASE")
        self.username = os.getenv("DB_USERNAME")
        self.password = os.getenv("DB_PASSWORD")

    def get_connection(self):
        """Returns an active, authenticated database connection link."""
        try:
            return pymssql.connect(
                server=self.server,
                user=self.username,
                password=self.password,
                database=self.database,
                timeout=30
            )
        except Exception as e:
            print(f"❌ Database connection failed: {e}")
            raise e
