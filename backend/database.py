import sqlite3
from contextlib import contextmanager
from pathlib import Path


DATABASE_PATH = Path(__file__).resolve().parent / "rice_grader.db"
DATABASE_TIMEOUT_SECONDS = 30
MAX_HISTORY_LIMIT = 200

# Single source of truth: sqlite column -> JSON key sent to the apps.
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
    """One connection per call: committed when the block ends, always closed.

    sqlite3's own context manager commits but never closes, which leaks a
    connection - and its WAL file handles - on every single query.
    """
    connection = sqlite3.connect(DATABASE_PATH, timeout=DATABASE_TIMEOUT_SECONDS)
    connection.row_factory = sqlite3.Row
    connection.execute(f"PRAGMA busy_timeout = {DATABASE_TIMEOUT_SECONDS * 1000}")
    try:
        yield connection
        connection.commit()
    finally:
        connection.close()


def init_database():
    with get_connection() as connection:
        connection.execute("PRAGMA journal_mode = WAL")
        connection.execute(
            "CREATE TABLE IF NOT EXISTS prediction_history ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, predicted_grade TEXT NOT NULL, "
            "confidence REAL NOT NULL DEFAULT 0, image_path TEXT, note TEXT, "
            "error TEXT, created_at TEXT NOT NULL)"
        )


def add_prediction(entry):
    with get_connection() as connection:
        cursor = connection.execute(
            "INSERT INTO prediction_history (predicted_grade, confidence, image_path, "
            "note, error, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            (
                entry["predicted_grade"],
                entry.get("confidence", 0),
                entry.get("image_path"),
                entry.get("note"),
                entry.get("error"),
                entry["created_at"],
            ),
        )
        return cursor.lastrowid


def list_predictions(limit=50):
    limit = max(1, min(int(limit), MAX_HISTORY_LIMIT))

    with get_connection() as connection:
        rows = connection.execute(
            f"SELECT {', '.join(FIELDS)} FROM prediction_history "
            "ORDER BY datetime(created_at) DESC, id DESC LIMIT ?",
            (limit,),
        ).fetchall()

    return [{key: row[column] for column, key in FIELDS.items()} for row in rows]


def clear_predictions():
    with get_connection() as connection:
        connection.execute("DELETE FROM prediction_history")
