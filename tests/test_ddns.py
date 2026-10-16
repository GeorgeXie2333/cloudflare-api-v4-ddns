"""Exercise the real shell script with isolated curl/crontab implementations."""
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "cf-v4-ddns.sh"
BASH = shutil.which("bash")
JQ = shutil.which("jq")
TOKEN = "example_test_token_not_a_real_credential"
ZONE_ID = "a" * 32
RECORD_ID = "b" * 32

CURL_STUB = r'''
import json, os, sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
args = sys.argv[1:]
url = args[args.index('--url') + 1] if '--url' in args else args[-1]
method = args[args.index('--request') + 1] if '--request' in args else 'GET'
payload = json.loads(args[args.index('--data') + 1]) if '--data' in args else None
request = {'url': url, 'method': method, 'payload': payload, 'args': args}
with open(os.environ['FAKE_REQUESTS'], 'a') as output:
    output.write(json.dumps(request) + '\n')
case = os.environ.get('FAKE_CASE', '')
if case == 'network-failure':
    print('simulated connection failure', file=sys.stderr)
    sys.exit(22)
if 'icanhazip.com' in url:
    if case == 'invalid-ip':
        print('<html>Service unavailable</html>')
    else:
        print(os.environ.get('FAKE_IP', '2001:db8::1234' if 'ipv6.' in url else '203.0.113.42'))
    sys.exit(0)
assert '--header' in args and args[-2:] == ['--header', '@-']
assert sys.stdin.read() == 'Authorization: Bearer ' + os.environ['FAKE_TOKEN'] + '\n'
if case == 'malformed-json':
    print('not JSON')
    sys.exit(0)
if case == 'api-error' or (case == 'update-rejected' and method in ('POST', 'PATCH')):
    print(json.dumps({'success': False, 'errors': [{'code': 10000, 'message': 'Authentication error'}]}))
    sys.exit(0)
path = urlsplit(url).path
if method in ('PATCH', 'POST'):
    result = {'id': 'b' * 32}
elif path.endswith('/zones'):
    result = [] if case == 'missing-zone' else [{'id': 'a' * 32}]
else:
    query = parse_qs(urlsplit(url).query)
    assert query['type'][0] in ('A', 'AAAA')
    result = [{'id': 'b' * 32, 'type': query['type'][0], 'name': query['name'][0], 'proxied': True}]
    if case == 'new-record':
        result = []
    elif case == 'duplicate-record':
        result *= 2
    elif case == 'invalid-list':
        result = None
print(json.dumps({'success': True, 'errors': [], 'result': result}, indent=2))
'''

CRON_STUB = r'''
import os, sys
from pathlib import Path
path = Path(os.environ['FAKE_CRONTAB'])
if sys.argv[1:] == ['-l']:
    if os.environ.get('FAKE_CRON_READ_ERROR'):
        print('permission denied', file=sys.stderr)
        sys.exit(1)
    if not path.exists():
        print('no crontab for test-user', file=sys.stderr)
        sys.exit(1)
    sys.stdout.write(path.read_text())
else:
    path.write_text(Path(sys.argv[1]).read_text())
'''

INSTALL_STUB = r'''
import os, sys
from pathlib import Path
with open(os.environ['FAKE_INSTALL_LOG'], 'a') as output:
    output.write(' '.join(sys.argv[1:]) + '\n')
if 'install' in sys.argv:
    (Path(os.environ['FAKE_BIN']) / 'jq').symlink_to(os.environ['FAKE_JQ'])
'''


@unittest.skipUnless(BASH and JQ, "bash and jq are required")
class DDNSTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cf-ddns tests ' % ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.config = self.root / "config" / "cloudflare-ddns" / "config.json"
        self.data = self.root / "data" / "cloudflare-ddns"
        self.requests = self.root / "requests.jsonl"
        self.crontab = self.root / "crontab"
        self.env = dict(os.environ)
        self.env.update(
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            XDG_CONFIG_HOME=str(self.root / "config"),
            XDG_DATA_HOME=str(self.root / "data"),
            FAKE_REQUESTS=str(self.requests), FAKE_CRONTAB=str(self.crontab),
            FAKE_TOKEN=TOKEN,
        )
        self.stub("curl", CURL_STUB)
        self.stub("crontab", CRON_STUB)

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!" + sys.executable + "\n" + body)
        path.chmod(0o700)

    def run_script(self, *args, answers="", success=True, extra_env=None):
        env = self.env | (extra_env or {})
        result = subprocess.run(
            [BASH, str(SCRIPT), *args], input=answers, text=True,
            capture_output=True, env=env, start_new_session=True, timeout=15,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        return result

    def configure(self, *, answers=None, args=(), extra_env=None, success=True):
        return self.run_script(
            *args, answers=answers if answers is not None else TOKEN + "\nexample.com\nhome\n\n\nn\n",
            extra_env=extra_env, success=success,
        )

    def calls(self):
        return [json.loads(line) for line in self.requests.read_text().splitlines()] if self.requests.exists() else []

    def cli(self, *args, **kwargs):
        return self.run_script("-k", TOKEN, "-z", "example.com", "-h", "home", *args, **kwargs)

    def test_first_run_saves_private_config_and_updates(self):
        result = self.configure()
        self.assertIn("配置已保存", result.stdout)
        self.assertIn("已更新", result.stdout)
        config = json.loads(self.config.read_text())
        self.assertEqual(config, dict(api_token=TOKEN, zone="example.com", record="home.example.com", record_type="A", ttl=1))
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)
        self.assertEqual(self.calls()[-1]["method"], "PATCH")
        self.assertEqual(self.calls()[-1]["payload"], dict(content="203.0.113.42", ttl=1))
        self.assertNotIn(TOKEN, self.requests.read_text())
        self.assertFalse(self.crontab.exists())

    def test_saved_configuration_runs_without_prompts_and_uses_cache(self):
        self.configure()
        before = len(self.calls())
        result = self.run_script("--run")
        self.assertIn("无需更新", result.stdout)
        self.assertEqual(len(self.calls()), before + 1)
        self.assertIn("icanhazip.com", self.calls()[-1]["url"])
        self.run_script("--run", "-f", "true")
        self.assertEqual(self.calls()[-1]["method"], "PATCH")

    def test_changed_ip_and_ttl_are_applied(self):
        self.configure()
        self.run_script("--run", extra_env={"FAKE_IP": "203.0.113.43"})
        self.assertEqual(self.calls()[-1]["payload"]["content"], "203.0.113.43")
        self.run_script("--run", "--ttl", "120", extra_env={"FAKE_IP": "203.0.113.43"})
        self.assertEqual(self.calls()[-1]["payload"]["ttl"], 120)
        self.assertEqual(json.loads(self.config.read_text())["ttl"], 1)

    def test_ipv6_selection_uses_ipv6_endpoint_and_separate_cache(self):
        self.configure()
        self.run_script("--run", "-t", "AAAA")
        calls = self.calls()[-4:]
        self.assertEqual(calls[0]["url"], "https://ipv6.icanhazip.com")
        self.assertIn("--ipv6", calls[0]["args"])
        self.assertIn("type=AAAA", calls[2]["url"])
        self.assertEqual(calls[-1]["payload"]["content"], "2001:db8::1234")
        self.assertEqual(len(list((self.data / "cache").glob("*.ip"))), 2)

    def test_apex_defaults_and_ipv6_numeric_selection(self):
        self.configure(answers=TOKEN + "\nExample.COM\n\n6\n\nn\n")
        config = json.loads(self.config.read_text())
        self.assertEqual(config["record"], "example.com")
        self.assertEqual(config["record_type"], "AAAA")

    def test_missing_record_is_created_without_proxy(self):
        self.configure(extra_env={"FAKE_CASE": "new-record"})
        request = self.calls()[-1]
        self.assertEqual(request["method"], "POST")
        self.assertEqual(request["payload"], dict(type="A", name="home.example.com", content="203.0.113.42", ttl=1, proxied=False))

    def test_reconfigure_keeps_defaults_and_scheduled_task_is_unique(self):
        self.crontab.write_text("0 0 * * * echo keep-this-job\n")
        self.configure(answers=TOKEN + "\nexample.com\nhome\n\n\n\n")
        self.run_script("--configure", answers="\n" * 6)
        table = self.crontab.read_text()
        self.assertIn("0 0 * * * echo keep-this-job\n", table)
        self.assertEqual(table.count("# cloudflare-ddns:"), 1)
        self.assertNotIn(TOKEN, table)
        self.assertTrue((self.data / "cf-v4-ddns.sh").is_file())
        self.assertEqual(stat.S_IMODE((self.data / "cf-v4-ddns.sh").stat().st_mode), 0o700)
        # Cron removes the backslash protecting percent before passing the command to sh.
        job = next(line for line in table.splitlines() if "# cloudflare-ddns:" in line)
        command = job.split(maxsplit=5)[5].replace(r"\%", "%")
        cron_env = {key: value for key, value in self.env.items() if key not in ("XDG_CONFIG_HOME", "XDG_DATA_HOME")}
        result = subprocess.run(["/bin/sh", "-c", command], env=cron_env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("无需更新", (self.data / "ddns.log").read_text())

    def test_crontab_read_failure_keeps_existing_tasks(self):
        original = "0 0 * * * echo keep-this-job\n"
        self.crontab.write_text(original)
        result = self.configure(answers=TOKEN + "\nexample.com\nhome\n\n\n\n", extra_env={"FAKE_CRON_READ_ERROR": "1"})
        self.assertEqual(self.crontab.read_text(), original)
        self.assertIn("无法读取现有 crontab", result.stdout)

    def test_custom_configs_have_independent_scheduled_jobs(self):
        self.configure(answers=TOKEN + "\nexample.com\nhome\n\n\n\n")
        second = self.root / "another config.json"
        self.configure(args=("--config", str(second)), answers=TOKEN + "\nexample.com\nv6\n6\n\n\n")
        self.assertTrue(second.exists())
        self.assertEqual(self.crontab.read_text().count("# cloudflare-ddns:"), 2)

    def test_invalid_inputs_are_reprompted_before_saving(self):
        self.configure(answers="\n" + TOKEN + "\nhttps://wrong.invalid/path\nexample.com\nother.invalid\nhome\nMX\nA\n2\n60\nn\n")
        config = json.loads(self.config.read_text())
        self.assertEqual(config["ttl"], 60)
        self.assertEqual(config["record"], "home.example.com")

    def test_eof_during_setup_does_not_save(self):
        self.configure(answers=TOKEN + "\n", success=False)
        self.assertFalse(self.config.exists())
        self.assertEqual(self.calls(), [])

    def test_run_with_no_config_does_not_prompt(self):
        result = self.run_script("--run", success=False)
        self.assertIn("--configure", result.stderr)
        self.assertNotIn("API 令牌（输入不显示）", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_legacy_flags_remain_noninteractive(self):
        self.cli("-t", "A", "-f", "true")
        self.assertFalse(self.config.exists())
        self.assertIn("name=home.example.com", self.calls()[-2]["url"])

    def test_failures_never_cache_success_or_schedule(self):
        for case in ("network-failure", "invalid-ip", "api-error", "malformed-json", "missing-zone", "duplicate-record", "invalid-list", "update-rejected"):
            with self.subTest(case=case):
                self.configure(extra_env={"FAKE_CASE": case}, success=False)
                self.assertEqual(list((self.data / "cache").glob("*.ip")), [])
                self.assertFalse(self.crontab.exists())
        self.run_script("--run")
        self.assertEqual(self.calls()[-1]["method"], "PATCH")

    def test_failed_update_preserves_previous_cache_and_retries(self):
        self.configure()
        cache = next((self.data / "cache").glob("*.ip"))
        previous = cache.read_text()
        self.run_script("--run", extra_env={"FAKE_IP": "203.0.113.43", "FAKE_CASE": "update-rejected"}, success=False)
        self.assertEqual(cache.read_text(), previous)
        self.run_script("--run", extra_env={"FAKE_IP": "203.0.113.43"})
        self.assertEqual(cache.read_text().strip(), "203.0.113.43")

    def test_invalid_cli_values_do_not_call_network(self):
        for args in (("-t", "MX"), ("--ttl", "59"), ("--ttl", "86401"), ("--ttl", "1.5"), ("-f", "maybe"), ("-h", "other.invalid")):
            with self.subTest(args=args):
                self.cli(*args, success=False)
                self.assertEqual(self.calls(), [])

    def test_invalid_ip_literals_are_not_sent_to_cloudflare(self):
        for ip in ("999.1.1.1", "1.2.3", "1.2.3.4\n1.2.3.5"):
            with self.subTest(ip=ip):
                self.cli(extra_env={"FAKE_IP": ip}, success=False)
                self.assertNotIn("api.cloudflare.com", self.calls()[-1]["url"])
        for ip in ("2001:::1", "1::2::3", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8::", "2001:db8::x"):
            with self.subTest(ip=ip):
                self.cli("-t", "AAAA", extra_env={"FAKE_IP": ip}, success=False)
                self.assertNotIn("api.cloudflare.com", self.calls()[-1]["url"])

    def test_config_data_is_never_executed(self):
        marker = self.root / "should-not-exist"
        token = '$(touch${IFS}"' + str(marker) + '")'
        # Token contains spaces from the test path: validation rejects it before use.
        self.config.parent.mkdir(parents=True)
        self.config.write_text(json.dumps(dict(api_token=token, zone="example.com", record="home.example.com", record_type="A", ttl=1)))
        self.run_script("--run", success=False)
        self.assertFalse(marker.exists())
        self.assertEqual(self.calls(), [])

    def test_corrupt_configuration_is_not_overwritten(self):
        self.config.parent.mkdir(parents=True)
        self.config.write_text("not JSON")
        self.run_script("--configure", success=False)
        self.assertEqual(self.config.read_text(), "not JSON")
        self.assertEqual(self.calls(), [])

    def test_missing_dependency_can_be_installed_with_default_answer(self):
        # Restrict PATH to test doubles and the non-network utilities the script uses.
        for name in ("dirname", "mkdir", "mktemp", "chmod", "mv", "cp", "cksum", "cat", "grep"):
            (self.bin / name).symlink_to(shutil.which(name))
        self.stub("apt-get", INSTALL_STUB)
        self.stub("sudo", "import subprocess, sys\nsys.exit(subprocess.call(sys.argv[1:]))\n")
        result = self.configure(answers="\n" + TOKEN + "\nexample.com\nhome\n\n\nn\n", extra_env={
            "PATH": str(self.bin), "FAKE_BIN": str(self.bin), "FAKE_JQ": JQ,
            "FAKE_INSTALL_LOG": str(self.root / "install.log"),
        })
        self.assertIn("缺少依赖", result.stdout)
        self.assertEqual((self.root / "install.log").read_text(), "update\ninstall -y jq\n")
        self.assertTrue(self.config.exists())

    def test_help_and_bad_options(self):
        self.assertIn("--configure", self.run_script("--help").stdout)
        self.run_script("--unknown", success=False)
        self.run_script("-k", success=False)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
