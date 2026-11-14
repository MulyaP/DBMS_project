"""Request-scoped database connections and transactions."""

from contextlib import contextmanager

import pymysql
from flask import current_app, g


class DatabaseConfigurationError(Exception):
    pass


# Connection lifecycle


def get_db():
    if 'db' not in g:
        config = current_app.config
        if not config.get('DB_PASSWORD'):
            raise DatabaseConfigurationError(
                'Set DB_PASSWORD in the local .env file, then restart Flask.'
            )
        g.db = pymysql.connect(
            host=config['DB_HOST'],
            port=config['DB_PORT'],
            user=config['DB_USER'],
            password=config['DB_PASSWORD'],
            database=config['DB_NAME'],
            charset='utf8mb4',
            cursorclass=pymysql.cursors.DictCursor,
            autocommit=True,
            connect_timeout=8,
            read_timeout=20,
            write_timeout=20,
            init_command=(
                'SET SESSION '
                "sql_mode='STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION,ONLY_FULL_GROUP_BY'"
            ),
        )
    return g.db


def close_db(error=None):
    connection = g.pop('db', None)
    if connection is not None:
        connection.close()


# Transactions for writes that span multiple statements


@contextmanager
def transaction():
    connection = get_db()
    connection.begin()
    try:
        yield connection
        connection.commit()
    except Exception:
        connection.rollback()
        raise
