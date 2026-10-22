import os
import traceback
from contextlib import ExitStack
import unittest
from unittest.mock import MagicMock, patch

from app import database


def init_with(*results):
    """Run init_database against a fake MySQL; return the SQL it executed."""
    connection = MagicMock()
    cursor = connection.cursor.return_value.__enter__.return_value
    cursor.fetchall.side_effect = list(results)
    with patch.object(database.mysql.connector, "connect", return_value=connection):
        database.init_database()
    return [call.args[0] for call in cursor.execute.call_args_list]


class DatabaseTests(unittest.TestCase):
    def test_railway_service_variables(self):
        with patch.dict(os.environ, {"MYSQLHOST": "mysql.railway.internal", "MYSQLPORT": "3307", "MYSQLUSER": "rice", "MYSQLPASSWORD": "example", "MYSQLDATABASE": "railway"}, clear=True):
            self.assertEqual(database.mysql_config(), {"host": "mysql.railway.internal", "port": 3307, "user": "rice", "password": "example", "database": "railway"})

    def test_url_decodes_credentials_and_takes_precedence(self):
        with patch.dict(os.environ, {"MYSQL_URL": "mysql://rice%40user:pass%2Fword@mysql.railway.internal:3307/rice", "MYSQL_PORT": "invalid"}, clear=True):
            config = database.mysql_config()
            self.assertEqual(config["password"], "pass/word")
            self.assertEqual(config["user"], "rice@user")
            self.assertEqual(config["database"], "rice")
            self.assertEqual(config["port"], 3307)

    def test_legacy_variables_still_work(self):
        with patch.dict(os.environ, {"MYSQL_HOST": "old-host", "MYSQLHOST": "railway-host"}, clear=True):
            self.assertEqual(database.mysql_config()["host"], "old-host")

    def test_bad_configuration_is_rejected_at_connection_time(self):
        for env in ({"MYSQL_PORT": "invalid"}, {"MYSQLPORT": "0"}, {"MYSQL_URL": "https://example.com/rice"}, {"MYSQL_URL": "mysql://user:pass@host"}, {"MYSQL_URL": "mysql://user:pass@host:0/rice"}):
            with self.subTest(env=env), patch.dict(os.environ, env, clear=True):
                with self.assertRaises(ValueError):
                    database.mysql_config()

    def test_connection_commits_success_and_closes(self):
        connection = MagicMock()
        with patch.object(database.mysql.connector, "connect", return_value=connection):
            with database.get_connection():
                pass
        connection.commit.assert_called_once()
        connection.close.assert_called_once()

    def test_history_index_is_added_to_existing_tables(self):
        # A table from an earlier version: no client column and no indexes.
        sql = init_with([("prediction_history",)], [], [], [])
        self.assertFalse(any(query.startswith("CREATE TABLE") for query in sql))
        self.assertIn("ALTER TABLE prediction_history ADD COLUMN client_hash CHAR(64) NULL", sql)
        self.assertTrue(any(query.startswith("CREATE INDEX idx_prediction_created_at") for query in sql))
        self.assertTrue(any(query.startswith("CREATE INDEX idx_prediction_client") for query in sql))

    def test_history_index_is_not_recreated_if_present(self):
        # A current schema must start for a user holding only SELECT, INSERT and
        # DELETE: MySQL denies such a user even CREATE TABLE IF NOT EXISTS.
        sql = init_with(*[[("already present",)]] * 4)
        self.assertTrue(sql)
        self.assertTrue(all(query.startswith("SHOW ") for query in sql), sql)

    def test_new_database_gets_the_complete_schema(self):
        sql = init_with([], [("client_hash",)], [("index",)], [("index",)])
        create = next(query for query in sql if query.startswith("CREATE TABLE"))
        for part in ("client_hash CHAR(64)", "idx_prediction_created_at", "idx_prediction_client"):
            self.assertIn(part, create)
        self.assertEqual([query for query in sql if not query.startswith("SHOW ")], [create])

    def test_history_reads_and_deletes_match_one_client(self):
        connection = MagicMock()
        cursor = connection.cursor.return_value.__enter__.return_value
        cursor.fetchall.return_value = []
        with patch.object(database.mysql.connector, "connect", return_value=connection):
            database.list_predictions("client-digest", 500)
            database.clear_predictions("client-digest")
            database.add_prediction({"predicted_grade": "Premium", "created_at": "now", "client_hash": "client-digest"})
        (select, select_args), (delete, delete_args), (insert, insert_args) = (
            call.args for call in cursor.execute.call_args_list
        )
        self.assertIn("WHERE client_hash = %s", select)
        self.assertEqual(select_args, ("client-digest", database.MAX_HISTORY_LIMIT))
        self.assertEqual((delete, delete_args), ("DELETE FROM prediction_history WHERE client_hash = %s", ("client-digest",)))
        self.assertIn("client_hash", insert)
        self.assertEqual(insert_args[-1], "client-digest")

    def test_malformed_url_never_echoes_the_password(self):
        # An unencoded "/" or "#" makes urllib read part of the password as the port.
        for url in ("mysql://rice_app:Secret/Part@db:3306/railway", "mysql://rice_app:Secret#Part@db/railway"):
            with self.subTest(url=url), patch.dict(os.environ, {"MYSQL_URL": url}, clear=True):
                with self.assertRaises(ValueError) as raised:
                    database.mysql_config()
                logged = "".join(traceback.format_exception(raised.exception))
                self.assertNotIn("Secret", logged)
                self.assertIn("Percent-encode", logged)

    def test_connection_rolls_back_failure_and_closes(self):
        connection = MagicMock()
        with patch.object(database.mysql.connector, "connect", return_value=connection):
            with self.assertRaises(RuntimeError):
                with database.get_connection():
                    raise RuntimeError("transaction failed")
        connection.commit.assert_not_called()
        connection.rollback.assert_called_once()
        connection.close.assert_called_once()

    def test_capacity_is_bounded_and_recovers_when_connections_close(self):
        with patch.object(database.mysql.connector, "connect", side_effect=lambda **config: MagicMock()) as connect:
            with ExitStack() as connections:
                for _ in range(4):
                    connections.enter_context(database.get_connection())
                with self.assertRaises(database.DatabaseBusyError):
                    with database.get_connection():
                        self.fail("An excess connection must not be opened.")
                self.assertEqual(connect.call_count, 4)
            with database.get_connection():
                pass
            self.assertEqual(connect.call_count, 5)

    def test_failed_connect_does_not_leak_capacity(self):
        with patch.object(database.mysql.connector, "connect", side_effect=OSError("offline")):
            for _ in range(8):
                with self.assertRaises(OSError):
                    with database.get_connection():
                        pass
        with patch.object(database.mysql.connector, "connect", return_value=MagicMock()):
            with database.get_connection():
                pass

    def test_cleanup_failure_preserves_original_error_and_frees_capacity(self):
        connection = MagicMock()
        connection.rollback.side_effect = OSError("rollback failed")
        connection.close.side_effect = OSError("close failed")
        with patch.object(database.mysql.connector, "connect", return_value=connection):
            for _ in range(8):
                with self.assertRaisesRegex(RuntimeError, "original operation failed"):
                    with database.get_connection():
                        raise RuntimeError("original operation failed")


if __name__ == "__main__":
    unittest.main()
