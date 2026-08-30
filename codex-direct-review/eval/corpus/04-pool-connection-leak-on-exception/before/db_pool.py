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


def run_query(pool, execute, sql):
    conn = pool.acquire()
    result = execute(conn, sql)
    pool.release(conn)
    return result
