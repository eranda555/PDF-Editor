import asyncio
import os
import signal
import shutil
from pathlib import Path


async def run_process(arguments: list[str], cwd: Path, timeout: int = 180) -> bytes:
    if not cwd.is_dir():
        raise ValueError('A per-job working directory is required')
    environment = {'PATH': os.environ.get('PATH', '/usr/local/bin:/usr/bin:/bin'),
                   'HOME': str(cwd), 'TMPDIR': str(cwd), 'LANG': 'C.UTF-8',
                   'OMP_NUM_THREADS': '1', 'OPENBLAS_NUM_THREADS': '1'}
    environment['QT_QPA_PLATFORM']='offscreen'
    if os.name!='nt':
        if not shutil.which('prlimit'):
            raise RuntimeError('Process resource limiter is required')
        arguments=['prlimit','--cpu=210','--fsize=52428800','--nofile=256','--',*arguments]
    if os.name != 'nt' and os.environ.get('REQUIRE_NETWORK_SANDBOX', 'true').lower() == 'true':
        if not shutil.which('bwrap'):
            raise RuntimeError('Filesystem and network sandbox is required')
        sandbox=['bwrap','--die-with-parent','--unshare-all','--cap-drop','ALL']
        for folder in ('/usr','/bin','/sbin','/lib','/lib64'):
            if Path(folder).exists():
                sandbox.extend(['--ro-bind',folder,folder])
        sandbox.extend(['--dir','/etc'])
        for item in ('/etc/fonts','/etc/ld.so.cache','/etc/passwd','/etc/group','/etc/nsswitch.conf'):
            if Path(item).exists():
                sandbox.extend(['--ro-bind',item,item])
        sandbox.extend(['--proc','/proc','--dev','/dev','--tmpfs','/tmp',
                        '--bind',str(cwd),str(cwd),'--chdir',str(cwd),'--'])
        arguments=sandbox+arguments
    process = await asyncio.create_subprocess_exec(*arguments, cwd=cwd,
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
        start_new_session=os.name != 'nt', env=environment)
    try:
        await asyncio.wait_for(process.wait(), timeout)
        if process.returncode != 0:
            raise RuntimeError('Conversion process failed')
        return b''
    finally:
        # Kill the whole session even if the parent exited but left descendants.
        if os.name != 'nt':
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                if process.returncode is None:
                    process.kill()
        elif process.returncode is None:
            process.kill()
        await process.wait()
