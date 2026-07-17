import repository


class _Result:
    def __init__(self, row):
        self.row = row

    def fetchone(self):
        return self.row


class _Connection:
    def __init__(self, content):
        self.content = content
        self.executed = []
        self.inserted = []

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def execute(self, sql, params):
        self.executed.append((sql, params))
        if sql.startswith("SELECT"):
            return _Result((self.content,))
        return _Result(None)

    def cursor(self):
        return self

    def executemany(self, sql, rows):
        self.inserted.append((sql, list(rows)))


class _Pool:
    def __init__(self, connection):
        self._connection = connection

    def connection(self):
        return self._connection


def test_pool_reads_database_url_lazily(monkeypatch):
    sentinel = object()
    seen = {}

    def fake_pool(database_url, **options):
        seen["database_url"] = database_url
        seen["options"] = options
        return sentinel

    monkeypatch.setattr(repository, "_POOL", None)
    monkeypatch.setattr(repository, "ConnectionPool", fake_pool)
    monkeypatch.setenv("DATABASE_URL", "postgresql://late-loaded")

    assert repository.pool() is sentinel
    assert seen == {
        "database_url": "postgresql://late-loaded",
        "options": {"min_size": 1, "max_size": 8, "open": True},
    }


def test_embedding_replacement_is_guarded_by_current_content(monkeypatch):
    connection = _Connection("current text")
    monkeypatch.setattr(repository, "pool", lambda: _Pool(connection))

    replaced = repository.replace_embeddings_if_content_matches(
        "capture",
        "user",
        "current text",
        [b"vector"],
        ["chunk"],
        "model",
        2,
        "hash",
    )

    assert replaced
    assert any(sql.startswith("DELETE") for sql, _ in connection.executed)
    assert connection.inserted[0][1] == [
        ("capture", "user", 0, b"vector", "chunk", "model", 2, "hash")
    ]


def test_embedding_replacement_rejects_stale_content(monkeypatch):
    connection = _Connection("newer text")
    monkeypatch.setattr(repository, "pool", lambda: _Pool(connection))

    replaced = repository.replace_embeddings_if_content_matches(
        "capture",
        "user",
        "older text",
        [b"vector"],
        ["chunk"],
        "model",
        2,
        "hash",
    )

    assert not replaced
    assert not any(sql.startswith("DELETE") for sql, _ in connection.executed)
    assert connection.inserted == []
