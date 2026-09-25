# _scripts/core/database.py
import os
from contextlib import contextmanager
import pymssql
from dotenv import load_dotenv


class DatabaseManager:
    """Manages connections to the test or production Azure SQL Server
    instance. `env` selects which one -- 'test' (default) or 'prod'.
    Defaults to 'test' so existing callers that construct DatabaseManager()
    with no arguments (e.g. frontend/app.py) are unaffected.
    """

    def __init__(self, env: str = "test"):
        if env not in ("test", "prod"):
            raise ValueError(f"env must be 'test' or 'prod', got {env!r}")

        self.env = env

        # Loads .env.<env> if it exists (local development). In CI this file
        # usually won't exist -- that's fine, load_dotenv() just does
        # nothing in that case, and the os.getenv() calls below pick up
        # whatever the workflow already set as real environment variables.
        load_dotenv(f".env.{env}")

        self.server = os.getenv("DB_SERVER")
        self.database = os.getenv("DB_DATABASE")
        self.username = os.getenv("DB_USERNAME")
        self.password = os.getenv("DB_PASSWORD")

        missing = [name for name, value in [
            ("DB_SERVER", self.server),
            ("DB_DATABASE", self.database),
            ("DB_USERNAME", self.username),
            ("DB_PASSWORD", self.password),
        ] if not value]
        if missing:
            raise ValueError(
                f"Missing required database configuration for env={env!r}: "
                f"{', '.join(missing)}. Set these in .env.{env} (local "
                f"development) or as environment variables (CI)."
            )

    def get_connection(self):
        """Returns a new, authenticated database connection. Caller is
        responsible for closing it and calling commit()/rollback() as
        needed -- this is how frontend/app.py already uses it.
        """
        try:
            return pymssql.connect(
                server=self.server,
                user=self.username,
                password=self.password,
                database=self.database,
                timeout=30,
            )
        except Exception as e:
            print(f"Database connection failed: {e}")
            raise

    @contextmanager
    def get_cursor(self):
        """Context manager that yields a cursor on a fresh connection,
        commits once on a clean exit, and rolls back if the block raises
        (including sys.exit(), which is why this catches BaseException
        rather than just Exception). Always closes the connection
        afterward. Used by _scripts/run_migrations.py.
        """
        conn = self.get_connection()
        cursor = conn.cursor()
        try:
            yield cursor
            conn.commit()
        except BaseException:
            conn.rollback()
            raise
        finally:
            conn.close()