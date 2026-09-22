#!/usr/bin/env python3
"""Exercise real venv processes and the non-root, private-release handoff.

CAPE/SQLAlchemy import fixtures deliberately avoid installing CAPE or touching
a database. These tests verify interpreter selection and the import boundary,
not database locking or Windows/INetSim integration.
"""
import json
import os
from pathlib import Path
import pwd
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import venv

REPO = Path(os.environ.get('CAPE_RUNTIME_TEST_ROOT', Path(__file__).resolve().parents[1]))


class RuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="cape-runtime-", dir="/tmp")
        cls.root = Path(cls.tmp.name)
        cls.root.chmod(0o755)
        cls.venv = cls.root / "Poetry env" / "runtime"
        venv.EnvBuilder(with_pip=False, symlinks=True).create(cls.venv)
        cls.python = str(cls.venv / "bin/python")
        cls.can_switch = os.getuid() == 0 and subprocess.run(
            ['runuser','-u','nobody','--','true'], capture_output=True).returncode == 0
        if os.environ.get('CAPE_RUNTIME_TEST_REQUIRE_NONROOT') == '1' and not cls.can_switch:
            raise RuntimeError('This required gate must exercise a real non-root service user')
        cls.user = "nobody" if cls.can_switch else pwd.getpwuid(os.getuid()).pw_name
        cls.cape = cls.root / "cape"
        cls.cape.mkdir()
        modules = {
            "lib/__init__.py": "",
            "lib/cuckoo/__init__.py": "",
            "lib/cuckoo/core/__init__.py": "",
            "lib/cuckoo/core/data/__init__.py": "",
            "lib/cuckoo/core/database.py": "class Database: pass\ndef init_database(**kwargs): raise AssertionError('preflight must not initialize DB')\n",
            "lib/cuckoo/core/data/machines.py": "class Machine: pass\n",
            "lib/cuckoo/core/data/db_common.py": "def _utcnow_naive(): pass\n",
            "lib/cuckoo/core/data/task.py": """from types import SimpleNamespace as N
TASK_RUNNING='running'
TASK_DISTRIBUTED='distributed'
TASK_COMPLETED='completed'
TASK_DISTRIBUTED_COMPLETED='distributed_completed'
class Task:
    __table__=N(c=N(status=N(type=N(enums=['running','distributed','completed']))))
""",
        }
        for name, content in modules.items():
            p = cls.cape / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content)
        site = Path(subprocess.check_output([cls.python, "-c", "import sysconfig; print(sysconfig.get_path('purelib'))"], text=True).strip())
        (site / "sqlalchemy.py").write_text("__version__='import-fixture'\ndef select(*args): pass\n")
        cls.private = cls.root / "private release"
        cls.private.mkdir(mode=0o700)
        for name in ["lib/cape-runtime.sh", "lib/maintenance.sh", "tools/cape_maintenance.py", "lib/deploy.sh"]:
            p = cls.private / name
            p.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / name, p)
        cls.bin = cls.root / "bin"
        cls.bin.mkdir()
        cls.write_executable(cls.bin / "systemctl", """import os,sys
prop=sys.argv[sys.argv.index('-p')+1]
print({'MainPID':os.environ.get('TEST_PID','0'),'User':os.environ['TEST_USER'],
       'ExecStart':os.environ.get('TEST_EXECSTART','')}.get(prop,''))
""")
        cls.poetry = cls.bin / "poetry"
        cls.write_executable(cls.poetry, """import os,pwd,sys
assert os.getcwd()==os.environ['CAPE_ROOT']
assert pwd.getpwuid(os.getuid()).pw_name==os.environ['TEST_USER']
if sys.argv[1:] == ['env','info','--executable']:
    if os.environ.get('TEST_OLD_POETRY'): sys.exit(2)
    print(os.environ['TEST_VENV']+'/bin/python')
elif sys.argv[1:] == ['env','info','--path']: print(os.environ['TEST_VENV'])
else: raise AssertionError('unexpected Poetry invocation')
""")

    @classmethod
    def write_executable(cls, path, body):
        path.write_text("#!/usr/bin/env python3\n" + body)
        path.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        self.children = []
        self.tx = "runtime-test-" + str(os.getpid()) + "-" + self._testMethodName
        self.env = dict(os.environ)
        for key in ["VIRTUAL_ENV", "PYTHONHOME", "CAPE_RUNTIME_PYTHON", "TEST_OLD_POETRY"]:
            self.env.pop(key, None)
        self.env.update(PATH=str(self.bin)+os.pathsep+os.environ['PATH'],
                        TEST_USER=self.user, TEST_PID="0", TEST_EXECSTART="",
                        TEST_VENV=str(self.venv), CAPE_ROOT=str(self.cape),
                        AUTODEPLOY_ROOT=str(self.private), DEPLOYMENT_ID=self.tx,
                        AD_STATE_ROOT=str(self.private / self.tx),
                        CAPE_MACHINE_LABEL="test-machine")

    def tearDown(self):
        for child in self.children:
            child.terminate()
            child.wait(timeout=5)
        stage = Path('/tmp') / ('cape-inetsim-autodeploy-' + self.tx)
        if stage.exists():
            shutil.rmtree(stage)

    def shell(self, script, ok=True):
        result = subprocess.run(["bash", "-Eeuo", "pipefail", "-c",
            'source "$AUTODEPLOY_ROOT/lib/maintenance.sh"\n' + script],
            env=self.env, cwd=self.private, text=True, capture_output=True, timeout=30)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def spawn_python(self, relative=False):
        ready = self.root / (self._testMethodName + '.ready')
        env = dict(self.env)
        env['PATH'] = str(self.venv / 'bin') + os.pathsep + env['PATH']
        child = subprocess.Popen(["python" if relative else self.python, "-c",
            "from pathlib import Path; import sys,time; Path(sys.argv[1]).touch(); time.sleep(30)", str(ready)],
            cwd=self.cape, env=env)
        self.children.append(child)
        for _ in range(100):
            if ready.exists(): break
            time.sleep(0.01)
        self.assertTrue(ready.exists())
        self.env['TEST_PID'] = str(child.pid)
        return child

    def test_live_venv_preserves_symlink_and_spaces(self):
        child = self.spawn_python()
        self.assertNotEqual(os.readlink(f'/proc/{child.pid}/exe'), self.python)
        result = self.shell('discover_cape_runtime; printf "%s\\n" "$CAPE_RUNTIME_PYTHON"')
        self.assertEqual(result.stdout.strip(), self.python)

    def test_relative_python_uses_process_path(self):
        self.spawn_python(relative=True)
        self.assertEqual(self.shell('cape_runtime_python').stdout.strip(), self.python)

    def test_runtime_survives_scheduler_stop(self):
        self.spawn_python()
        result = self.shell('discover_cape_runtime; export TEST_PID=0; discover_cape_runtime; cape_runtime_python')
        self.assertEqual(result.stdout.strip(), self.python)

    def test_stopped_service_direct_execstart(self):
        self.env['TEST_EXECSTART'] = '{ path=' + self.python + '; argv[]=' + shlex.quote(self.python) + ' cuckoo.py ; ignore_errors=no ; }'
        self.assertEqual(self.shell('cape_runtime_python').stdout.strip(), self.python)

    def test_stopped_poetry_service_uses_owner_and_project(self):
        self.env['TEST_EXECSTART'] = '{ argv[]=' + str(self.poetry) + ' run python cuckoo.py ; ignore_errors=no ; }'
        self.assertEqual(self.shell('cape_runtime_python').stdout.strip(), self.python)

    def test_older_poetry_path_fallback(self):
        self.env['TEST_EXECSTART'] = '{ argv[]=' + str(self.poetry) + ' run python cuckoo.py ; ignore_errors=no ; }'
        self.env['TEST_OLD_POETRY'] = '1'
        self.assertEqual(self.shell('cape_runtime_python').stdout.strip(), self.python)

    def test_unknown_environment_does_not_choose_host_python(self):
        self.assertNotEqual(self.shell('cape_runtime_python', ok=False).returncode, 0)

    def test_private_release_handoff_preflight_has_no_db_effect(self):
        self.spawn_python()
        result = self.shell('cape_maintenance_tool preflight')
        data = json.loads(result.stdout)
        self.assertEqual(data['python'], self.python)
        self.assertEqual(data['prefix'], str(self.venv))
        self.assertEqual(data['cwd'], str(self.cape))
        self.assertNotIn('distributed_completed', data['active_statuses'])
        self.assertFalse((self.private / self.tx / 'cape-maintenance-guard.json').exists())
        self.assertFalse((Path('/tmp') / ('cape-inetsim-autodeploy-' + self.tx)).exists())

    def test_nonroot_staged_handoff(self):
        if not self.can_switch:
            self.skipTest('runtime cannot switch UID; required sudo CI exercises this case')
        self.assertEqual(self.env['TEST_USER'], 'nobody')
        self.test_private_release_handoff_preflight_has_no_db_effect()

    def test_wrong_environment_fails_real_import(self):
        empty = self.root / 'empty-env'
        venv.EnvBuilder(with_pip=False).create(empty)
        self.env['CAPE_RUNTIME_PYTHON'] = str(empty / 'bin/python')
        result = self.shell('cape_maintenance_tool preflight', ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No module named 'sqlalchemy'", result.stderr)

    def test_failed_preflight_cannot_enter_appliance_stage(self):
        result = self.shell('''
source "$AUTODEPLOY_ROOT/lib/deploy.sh"
require_root(){ :; }
transaction_lock_acquire(){ :; }
run_discovery(){ :; }
deploy_assert_supported_environment(){ :; }
deploy_initialize_or_resume_state(){ DEPLOYMENT_PHASE=planned; }
cape_preflight_runtime(){ return 1; }
deploy_rollback_after_error(){ echo preflight-stopped; exit "$1"; }
deploy_stage_non_disruptive(){ echo UNEXPECTED-APPLIANCE-MUTATION; }
deploy_run
''', ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('preflight-stopped', result.stdout)
        self.assertNotIn('UNEXPECTED-APPLIANCE-MUTATION', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
