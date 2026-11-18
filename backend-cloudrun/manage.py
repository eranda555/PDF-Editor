import asyncio
from pathlib import Path
from app.config import get_settings
from app.db import Database


async def main():
    from app.queue.procrastinate_app import app
    settings = get_settings()
    db = Database(settings.database_url.get_secret_value())
    await db.pool.open()
    try:
        async with db.connection() as connection:
            for migration in sorted(Path(__file__).with_name('migrations').glob('*.sql')):
                await connection.execute(migration.read_text())
        async with app.open_async():
            await app.schema_manager.apply_schema_async()
    finally:
        await db.pool.close()


if __name__ == '__main__':
    asyncio.run(main())
