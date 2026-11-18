from contextlib import asynccontextmanager
from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool


class Database:
    def __init__(self, dsn: str):
        self.pool = AsyncConnectionPool(dsn, min_size=0, max_size=5, open=False,
                                        kwargs={'row_factory': dict_row})

    @asynccontextmanager
    async def connection(self):
        async with self.pool.connection() as conn:
            yield conn

    async def one(self, sql: str, params=()):
        async with self.connection() as conn:
            cursor = await conn.execute(sql, params)
            return await cursor.fetchone()

    async def execute(self, sql: str, params=()):
        async with self.connection() as conn:
            await conn.execute(sql, params)
