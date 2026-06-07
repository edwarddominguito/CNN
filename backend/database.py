import sqlite3
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent
DATABASE_PATH = BASE_DIR / "rice_grader.db"


def get_connection():
    connection = sqlite3.connect(DATABASE_PATH)
    connection.row_factory = sqlite3.Row
    return connection


def init_database():
    with get_connection() as connection:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS prediction_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                predicted_grade TEXT NOT NULL,
                confidence REAL NOT NULL DEFAULT 0,
                image_path TEXT,
                note TEXT,
                error TEXT,
                created_at TEXT NOT NULL
            )
            """
        )
        connection.commit()


def add_prediction(entry):
    with get_connection() as connection:
        cursor = connection.execute(
            """
            INSERT INTO prediction_history (
                predicted_grade,
                confidence,
                image_path,
                note,
                error,
                created_at
            )
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                entry["predicted_grade"],
                entry.get("confidence", 0),
                entry.get("image_path"),
                entry.get("note"),
                entry.get("error"),
                entry["created_at"],
            ),
        )
        connection.commit()
        return cursor.lastrowid


def list_predictions(limit=50):
    with get_connection() as connection:
        rows = connection.execute(
            """
            SELECT
                id,
                predicted_grade,
                confidence,
                image_path,
                note,
                error,
                created_at
            FROM prediction_history
            ORDER BY datetime(created_at) DESC, id DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()

    return [_row_to_api(row) for row in rows]


def clear_predictions():
    with get_connection() as connection:
        connection.execute("DELETE FROM prediction_history")
        connection.commit()


def _row_to_api(row):
    return {
        "id": row["id"],
        "predictedGrade": row["predicted_grade"],
        "confidence": row["confidence"],
        "imagePath": row["image_path"],
        "note": row["note"],
        "error": row["error"],
        "createdAt": row["created_at"],
    }
