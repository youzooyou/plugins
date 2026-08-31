class TransientError(Exception):
    """Raised for errors that are safe to retry (e.g. a dropped connection)."""


class ConnectionPool:
    def __init__(self):
        self._available = ["conn-1", "conn-2", "conn-3"]
        self._in_use = set()

    def acquire(self):
        conn = self._available.pop()
        self._in_use.add(conn)
        return conn

    def release(self, conn):
        self._in_use.discard(conn)
        self._available.append(conn)


def run_query(pool, execute, sql, max_retries=3):
    last_error = None
    for attempt in range(max_retries):
        conn = pool.acquire()
        try:
            result = execute(conn, sql)
            pool.release(conn)
            return result
        except TransientError as exc:
            last_error = exc
            continue
    raise last_error
