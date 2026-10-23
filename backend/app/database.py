import logging
import os
from contextlib import contextmanager
from threading import BoundedSemaphore
from urllib.parse import unquote, urlsplit

import mysql.connector

DATABASE_TIMEOUT_SECONDS = 5
MAX_HISTORY_LIMIT = 200
INVALID_URL = (
    "MYSQL_URL must be a valid mysql:// connection URL. Percent-encode special "
    "characters in its user name and password."
)
connection_slots = BoundedSemaphore(4)
logger = logging.getLogger("rice_backend.database")


class DatabaseBusyError(RuntimeError):
    """All bounded connection slots are in use; callers should retry later."""


def mysql_config():
    """Read Railway's URL or service variables without exposing credentials in logs.

    Parse on connection, so invalid configuration produces a recoverable service
    error rather than an exception while importing the application.
    """
    url = os.getenv("MYSQL_URL")
    if url:
        try:
            parsed = urlsplit(url)
            port = 3306 if parsed.port is None else parsed.port
        except ValueError:
            # urllib quotes the text it could not parse, which can be part of a
            # password holding an unencoded "/", "?" or "#". Never chain it.
            raise ValueError(INVALID_URL) from None
        if parsed.scheme not in {"mysql", "mysql+mysqlconnector"} or not parsed.hostname:
            raise ValueError(INVALID_URL)
        if not 1 <= port <= 65535:
            raise ValueError("MySQL port must be between 1 and 65535.")
        config = {
            "host": parsed.hostname,
            "port": port,
            "user": unquote(parsed.username or "root"),
            "password": unquote(parsed.password or ""),
            "database": unquote(parsed.path.lstrip("/")),
        }
        if not config["database"]:
            raise ValueError("MYSQL_URL must include a database name.")
        return config

    def setting(name, railway_name, default):
        return os.getenv(name, os.getenv(railway_name, default))

    port = int(setting("MYSQL_PORT", "MYSQLPORT", "3306"))
    if not 1 <= port <= 65535:
        raise ValueError("MySQL port must be between 1 and 65535.")
    return {
        "host": setting("MYSQL_HOST", "MYSQLHOST", "localhost"),
        "port": port,
        "user": setting("MYSQL_USER", "MYSQLUSER", "root"),
        "password": setting("MYSQL_PASSWORD", "MYSQLPASSWORD", ""),
        "database": setting("MYSQL_DATABASE", "MYSQLDATABASE", "rice_classifier"),
    }


# Single source of truth: database column -> JSON key sent to the apps.
# Adding a column here updates the schema read, the SELECT, and the response.
FIELDS = {
    "id": "id",
    "predicted_grade": "predictedGrade",
    "confidence": "confidence",
    "image_path": "imagePath",
    "note": "note",
    "error": "error",
    "created_at": "createdAt",
}


@contextmanager
def get_connection():
    """One connection per call: committed when the block ends, always closed."""
    if not connection_slots.acquire(blocking=False):
        raise DatabaseBusyError("The history database is busy. Please try again shortly.")
    connection = None
    try:
        connection = mysql.connector.connect(
            **mysql_config(),
            connection_timeout=DATABASE_TIMEOUT_SECONDS,
            read_timeout=10,
            write_timeout=10,
            time_zone="+00:00",
        )
        yield connection
        connection.commit()
    except Exception:
        if connection is not None:
            try:
                connection.rollback()
            except Exception:
                # A lost connection often cannot roll back. Preserve the query's
                # original exception rather than replacing it with cleanup noise.
                logger.warning("Could not roll back a failed database operation.")
        raise
    finally:
        try:
            if connection is not None:
                try:
                    connection.close()
                except Exception:
                    logger.warning("Could not close a database connection cleanly.")
        finally:
            connection_slots.release()


def init_database():
    """Create or upgrade the history table, running DDL only for what is missing.

    MySQL refuses even CREATE TABLE IF NOT EXISTS to a user without the CREATE
    privilege. Checking first lets the app run as a user limited to SELECT, INSERT
    and DELETE on this table once the schema is current (docs/RAILWAY.md).
    """
    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("SHOW TABLES LIKE 'prediction_history'")
            if not cursor.fetchall():
                cursor.execute(
                    "CREATE TABLE IF NOT EXISTS prediction_history ("
                    "id BIGINT UNSIGNED PRIMARY KEY AUTO_INCREMENT, "
                    "predicted_grade VARCHAR(100) NOT NULL, "
                    "confidence DOUBLE NOT NULL DEFAULT 0, image_path TEXT, note TEXT, "
                    "error TEXT, created_at VARCHAR(64) NOT NULL, client_hash CHAR(64), "
                    "INDEX idx_prediction_created_at (created_at, id), "
                    "INDEX idx_prediction_client (client_hash, created_at, id))"
                )
            # Tables from earlier versions predate per-client history. The column
            # is nullable, so their rows are kept, readable by no client.
            cursor.execute("SHOW COLUMNS FROM prediction_history LIKE 'client_hash'")
            if not cursor.fetchall():
                cursor.execute("ALTER TABLE prediction_history ADD COLUMN client_hash CHAR(64) NULL")
            # Existing installations also need the indexes: LIMIT alone otherwise
            # still sorts the entire history table for every request.
            for name, columns in (
                ("idx_prediction_created_at", "created_at, id"),
                ("idx_prediction_client", "client_hash, created_at, id"),
            ):
                cursor.execute(f"SHOW INDEX FROM prediction_history WHERE Key_name = '{name}'")
                if not cursor.fetchall():
                    cursor.execute(f"CREATE INDEX {name} ON prediction_history ({columns})")
        if connection.user == "root":
            logger.warning(
                "Connected to MySQL as root. Use a dedicated least-privilege user "
                "for deployments; see docs/RAILWAY.md."
            )


def check_connection():
    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            cursor.fetchone()


def add_prediction(entry):
    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                "INSERT INTO prediction_history (predicted_grade, confidence, image_path, "
                "note, error, created_at, client_hash) VALUES (%s, %s, %s, %s, %s, %s, %s)",
                (
                    entry["predicted_grade"],
                    entry.get("confidence", 0),
                    entry.get("image_path"),
                    entry.get("note"),
                    entry.get("error"),
                    entry["created_at"],
                    entry.get("client_hash"),
                ),
            )
            return cursor.lastrowid


# Both queries match one client's rows only. SQL never treats NULL as equal, so
# rows saved without a client (and a missing hash) match nothing.
def list_predictions(client_hash, limit=50):
    limit = max(1, min(int(limit), MAX_HISTORY_LIMIT))

    with get_connection() as connection:
        with connection.cursor(dictionary=True) as cursor:
            # The API normalizes incoming timestamps to UTC ISO strings.
            cursor.execute(
                f"SELECT {', '.join(FIELDS)} FROM prediction_history WHERE client_hash = %s "
                "ORDER BY created_at DESC, id DESC LIMIT %s",
                (client_hash, limit),
            )
            rows = cursor.fetchall()

    return [{key: row[column] for column, key in FIELDS.items()} for row in rows]


def clear_predictions(client_hash):
    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("DELETE FROM prediction_history WHERE client_hash = %s", (client_hash,))
