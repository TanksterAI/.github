"""Tests for the light-lane lint in .github/workflows/workflows-lint.yml.

The lint is the run: script of the "Light jobs stay Docker-free" step.
self-check.yml extracts it with yq and points LIGHT_LANE_LINT at the file;
run by hand, this extracts it itself (with PyYAML or yq v4):

    python3 -m unittest discover -s tests/light-lane -v

Standard library only, and offline: action metadata comes from recorded
files under fixtures/actions, except in the tests that start a local HTTP
server to stand in for the GitHub API.
"""

import contextlib
import http.server
import importlib.util
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FIXTURES = os.path.join(HERE, "fixtures")
WORKFLOWS = os.path.join(ROOT, ".github", "workflows")
STEP = "Light jobs stay Docker-free"
TEMP_FILES = []

# The contract's expression for a light-capable job in a shared reusable
# workflow, and the one it replaced.
CONTRACT = (
    "${{ inputs.runs-on || (inputs.light && vars.CI_LIGHT_RUNNER == 'tankster-light' "
    "&& format('tankster-light-{0}-{1}', github.run_id, github.run_attempt)) "
    "|| vars.CI_RUNNER || 'ubuntu-latest' }}"
)
OLD_REUSABLE = "${{ inputs.runs-on || vars.CI_RUNNER || 'ubuntu-latest' }}"
OLD_PLAIN = "${{ vars.CI_RUNNER || 'ubuntu-latest' }}"
OWN = (
    "${{ (vars.CI_LIGHT_RUNNER == 'tankster-light' "
    "&& format('tankster-light-{0}-{1}', github.run_id, github.run_attempt)) "
    "|| vars.CI_RUNNER || 'ubuntu-latest' }}"
)

# Every job these workflows run is Docker-free and on the light lane.
LIGHT_WORKFLOWS = {
    "auto-merge-gate.yml": ["gate"],
    "claude-address-feedback.yml": ["credentials", "address"],
    "conflict-sweep.yml": ["credentials", "detect", "resolve"],
    "lockfile.yml": ["lockfile"],
    "node-ci.yml": ["check"],
    "python-ci.yml": ["verify"],
    "runtime-gate-flows.yml": ["save"],
    "rust-ci.yml": ["verify"],
    "security.yml": ["scan"],
    "workflows-lint.yml": ["actionlint"],
}
# Off the lane unless a caller turns it on: the agentic sessions, because a
# re-run after the light runner's egress stop would repeat the session; and
# rust-ci, because the light image has no C linker or rustup.
LIGHT_OFF_BY_DEFAULT = {"claude-address-feedback.yml", "conflict-sweep.yml", "rust-ci.yml"}
# They run the caller's installs, which may compile native code: their light
# input says the light image has no compiler (security.yml's python audit
# installs the caller's package).
NO_TOOLCHAIN_NOTE = {"node-ci.yml", "python-ci.yml", "lockfile.yml", "security.yml"}
# These keep their runner expression: Docker (or, for lighthouse-ci, Chrome
# and its system libraries, not yet tried on Cloud Run).
NOT_LIGHT = ["lighthouse-ci.yml", "runtime-gate.yml", "claude-review.yml"]


def _extract_script():
    path = os.environ.get("LIGHT_LANE_LINT")
    if path:
        return path
    with open(os.path.join(WORKFLOWS, "workflows-lint.yml"), encoding="utf-8") as handle:
        text = handle.read()
    try:
        import yaml

        data = yaml.safe_load(text)
        steps = data["jobs"]["actionlint"]["steps"]
        script = next(s["run"] for s in steps if s.get("name") == STEP)
    except ImportError:
        script = subprocess.run(
            ["yq", '.jobs.actionlint.steps[] | select(.name == "' + STEP + '") | .run', "-"],
            input=text, capture_output=True, text=True, check=True,
        ).stdout
    handle = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False, encoding="utf-8")
    with handle:
        handle.write(script)
    TEMP_FILES.append(handle.name)
    return handle.name


def _load_module():
    spec = importlib.util.spec_from_file_location("light_lane_lint", _extract_script())
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


lint = _load_module()


def tearDownModule():
    for name in TEMP_FILES:
        with contextlib.suppress(OSError):
            os.unlink(name)


def _temp_yaml(text):
    handle = tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False, encoding="utf-8")
    with handle:
        handle.write(text)
    TEMP_FILES.append(handle.name)
    return handle.name


class Recorded(lint.Resolver):
    """Answers the GitHub API from fixtures/actions/<owner>/<repo>/<ref>/<path>.fixture."""

    def __init__(self):
        super().__init__(root=FIXTURES, api="http://unused.invalid", token="")
        self.calls = []

    def _get(self, owner, repo, path, ref):
        self.calls.append((owner, repo, path, ref))
        file = os.path.join(FIXTURES, "actions", owner, repo, ref, path + ".fixture")
        if os.path.isfile(file):
            with open(file, encoding="utf-8") as handle:
                return handle.read(), None
        return None, "not found"


class Summaries(lint.Resolver):
    """The actions the shipped light jobs use, summarised from their action.yml
    at the pinned ref (read Nov 2026). The composites' run steps were read too
    and call no container tool; the live check is the workflows-lint run on
    this repository, which reads every one through the API."""

    USING = {
        "actions/checkout@v7.0.1": "node24",
        "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1": "node24",
        "actions/setup-node@v7.0.0": "node24",
        "actions/setup-node@820762786026740c76f36085b0efc47a31fe5020": "node24",
        "actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97": "node24",
        "actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e": "node24",
        "actions/upload-artifact@v7.0.1": "node24",
        "actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333": "node24",
        "actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9": "node24",
        "actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9": "node24",
        "pnpm/action-setup@v6.0.10": "node24",
        "Swatinem/rust-cache@6323deb102c322ba6fcbdcafc7e3dddab59af2b6": "node24",
        "oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6": "node24",
    }
    COMPOSITE = {
        "TanksterAI/.github/.github/actions/runtime-gate@7e22b13255bfa7fadfdec580fc41a359985b0b61": [
            "actions/setup-node@820762786026740c76f36085b0efc47a31fe5020"
        ],
        # #27 changed only the toolkit's scripts; its action.yml is the same.
        "TanksterAI/.github/.github/actions/runtime-gate@087cbb6d99cfdbd2f0a78c47de08adeaea92dbb2": [
            "actions/setup-node@820762786026740c76f36085b0efc47a31fe5020"
        ],
        "anthropics/claude-code-action@2dca132ff0e0c4094ce6048b422c6915a071210b": [
            "oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6"
        ],
        # One sh step that runs main.sh (prebuilt binaries over curl) and a
        # pwsh step for Windows; neither calls a container tool.
        "taiki-e/install-action@4cef1412cce204788f482e778a0b9187f9626a29": [],
    }

    def __init__(self):
        super().__init__(root=ROOT, api="http://unused.invalid", token="")

    def action(self, uses):
        if uses in self.USING:
            return {"runs": {"using": self.USING[uses]}}, None
        if uses in self.COMPOSITE:
            return {"runs": {"using": "composite", "steps": [{"uses": u} for u in self.COMPOSITE[uses]]}}, None
        return None, "no summary recorded for " + uses


def _problems(path, resolver):
    _, found = lint.check_file(path, resolver)
    return found


class Fixtures(unittest.TestCase):
    def test_pass_fixture_has_no_problems(self):
        found = _problems(os.path.join(FIXTURES, "pass.yml"), Recorded())
        self.assertEqual(found, [], "\n".join(m for _, _, m in found))

    def test_pass_fixture_counts_its_light_jobs(self):
        light, _ = lint.check_file(os.path.join(FIXTURES, "pass.yml"), Recorded())
        self.assertEqual(light, 6)

    def test_fail_fixture_reports_every_job_as_expected(self):
        path = os.path.join(FIXTURES, "fail.yml")
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        expected = dict(re.findall(r"^  ([\w-]+): # expect: (.+)$", text, re.M))
        self.assertGreater(len(expected), 20)
        found = _problems(path, Recorded())
        by_job = {}
        for line, job, message in found:
            by_job.setdefault(job, []).append(message)
            self.assertEqual(line, lint.job_line(text, job))
        self.assertEqual(sorted(by_job), sorted(expected))
        for job, want in expected.items():
            self.assertTrue(
                any(want in message for message in by_job[job]),
                "{}: wanted {!r}, got {!r}".format(job, want, by_job[job]),
            )

    def test_main_prints_annotations_and_fails(self):
        out = io.StringIO()
        old = lint.Resolver
        lint.Resolver = Recorded
        try:
            with contextlib.redirect_stdout(out):
                code = lint.main([os.path.join(FIXTURES, "fail.yml"), os.path.join(FIXTURES, "pass.yml")])
        finally:
            lint.Resolver = old
        self.assertEqual(code, 1)
        self.assertIn("::error file=", out.getvalue())
        self.assertRegex(out.getvalue(), r"\d+ light job\(s\) checked, \d+ problem\(s\)\n$")

    def test_main_passes_on_the_pass_fixture(self):
        out = io.StringIO()
        old = lint.Resolver
        lint.Resolver = Recorded
        try:
            with contextlib.redirect_stdout(out):
                code = lint.main([os.path.join(FIXTURES, "pass.yml")])
        finally:
            lint.Resolver = old
        self.assertEqual(code, 0, out.getvalue())

    def test_file_without_light_label_is_not_parsed(self):
        path = _temp_yaml("this: [is: not, valid yaml\n")
        self.assertEqual(lint.check_file(path, Recorded()), (0, []))

    def test_unparseable_light_file_fails_closed(self):
        path = _temp_yaml("jobs: [tankster-light\n")
        light, found = lint.check_file(path, Recorded())
        self.assertEqual(len(found), 1)
        self.assertIn("cannot read this file", found[0][2])


class DockerCommands(unittest.TestCase):
    # The independent review's probe cases, plus the guards of S4.
    RUNS = {
        "docker run x": "docker", "sudo docker ps": "docker", "  docker compose up": "docker",
        "foo && docker build .": "docker", "! docker info": "docker",
        "if ! docker info; then :; fi": "docker", "x=$(docker ps)": "docker",
        '"docker" run x': "docker", "/usr/bin/docker run": "docker",
        "DOCKER_BUILDKIT=1 docker build .": "docker", "eval docker ps": "docker",
        "nice docker ps": "docker", "nice -n 5 docker ps": "docker", "exec 3>&1 docker": "docker",
        "kind create cluster": "kind", "minikube start": "minikube", "docker\\\n run": "docker",
        "echo hi | xargs -I{} docker rm {}": "docker", "xargs -I {} docker rm {}": "docker",
        "time  docker ps": "docker", "sh -c 'docker ps'": "docker",
        'bash -c "docker run x"': "docker", "earthly +build": "earthly", "act -j test": "act",
        "dagger call test": "dagger", "buildctl build": "buildctl",
        "docker-compose up": "docker-compose", "nerdctl run": "nerdctl", "podman run": "podman",
        "buildah bud .": "buildah", "lima nerdctl run": "nerdctl", "pnpm exec docker ps": "docker",
        "cd x; docker ps": "docker", "( docker ps )": "docker", "{ docker ps; }": "docker",
        "command docker ps": "docker", "sudo -u root docker ps": "docker",
        "env -i FOO=1 docker ps": "docker", "timeout 5 docker ps": "docker",
        "docker ps 2>/dev/null": "docker", "`docker ps`": "docker",
        'echo "$(docker version --format \'{{.Server.Version}}\')"': "docker",
        'echo "id: `docker ps -q`"': "docker",
        # Heredocs: a body a shell reads is a script; after the body, and
        # after a `<<` inside quotes, lines are commands again.
        "bash <<'EOF'\ndocker ps\nEOF": "docker",
        "cat <<EOF | sh\ndocker ps\nEOF": "docker",
        "cat > a <<'EOF'\ntext\nEOF\ndocker ps": "docker",
        "cat <<A <<B\na\nA\nb\nB\ndocker ps": "docker",
        "cat <<-EOF\n\tdocker run\n\tEOF\ndocker ps": "docker",
        "echo '<<EOF'\ndocker ps": "docker",
        'echo "a <<EOF b"\ndocker ps': "docker",
        "read -r x <<< word\ndocker ps": "docker",
    }
    WORDS = [
        "make docker-up", "bash scripts/up.sh", "npx testcontainers", "skopeo copy a b",
        "echo 'use docker run to start'", "# docker run", "npm run docker:up",
        "echo docker", "npm test  # then docker run, later", 'echo "docker run" # docker',
        "cat Dockerfile", "dockerd --version", "export DOCKER_HOST=x", "my-docker-thing run",
        "./scripts/docker_helper.sh", "command -v docker", "command -V docker", "which docker",
        "type docker", "hash docker", "if ! command -v docker >/dev/null; then exit 0; fi",
        "cat > notes.md <<'EOF'\ndocker run is not used here\nEOF",
        "cat <<-EOF\n\tkind create cluster\n\tEOF\necho ok",
        'python3 - <<EOF\nimport shutil\ndocker = shutil.which("docker")\nEOF',
        'cat <<"END"\ndocker ps\nEND',
    ]

    def test_commands(self):
        for script, tool in self.RUNS.items():
            self.assertEqual([t for _, t in lint.docker_commands(script)], [tool], script)

    def test_words(self):
        for script in self.WORDS:
            self.assertEqual(lint.docker_commands(script), [], script)

    def test_line_numbers(self):
        self.assertEqual(lint.docker_commands("echo a\n\ndocker ps\n"), [(3, "docker")])
        self.assertEqual(lint.docker_commands("echo a\ndocker \\\n  ps\n"), [(2, "docker")])

    def test_the_lint_does_not_flag_its_own_source(self):
        with open(_extract_script(), encoding="utf-8") as handle:
            source = handle.read()
        self.assertEqual(lint.docker_commands(source), [])
        # And it never could from where it runs: a python3 step is not
        # shell, so even a line that starts with a tool name is not read.
        job = {"runs-on": OWN, "steps": [{"shell": "python3 {0}", "run": source + "\ndocker = 1\n"}]}
        self.assertEqual(lint.job_problems(job, Recorded()), [])


class Shells(unittest.TestCase):
    SCRIPT = 'docker = shutil.which("docker")\n'

    def problems(self, step, job_defaults=None, workflow_defaults=None):
        job = {"runs-on": OWN, "steps": [dict(step, run=self.SCRIPT)]}
        if job_defaults:
            job["defaults"] = {"run": {"shell": job_defaults}}
        workflow = {"run": {"shell": workflow_defaults}} if workflow_defaults else None
        return lint.job_problems(job, Recorded(), workflow)

    def test_shell_steps_are_read(self):
        for shell in [None, "bash", "sh", "bash -e {0}", "bash --noprofile --norc -eo pipefail {0}", "/bin/sh -e {0}"]:
            step = {} if shell is None else {"shell": shell}
            self.assertEqual(len(self.problems(step)), 1, shell)

    def test_other_shells_are_not(self):
        for shell in ["python", "python3 {0}", "pwsh", "powershell", "cmd", "node {0}", "perl {0}"]:
            self.assertEqual(self.problems({"shell": shell}), [], shell)

    def test_defaults_decide_when_the_step_does_not(self):
        self.assertEqual(self.problems({}, job_defaults="python"), [])
        self.assertEqual(self.problems({}, workflow_defaults="pwsh"), [])
        self.assertEqual(len(self.problems({}, job_defaults="bash", workflow_defaults="pwsh")), 1)
        self.assertEqual(len(self.problems({"shell": "bash"}, job_defaults="python")), 1)


class LightInputType(unittest.TestCase):
    def check(self, light_input):
        inputs = "\n      light:\n        type: {}\n".format(light_input) if light_input else ""
        path = _temp_yaml(
            "on:\n  workflow_call:\n    inputs:\n      runs-on:\n        type: string\n" + inputs
            + "jobs:\n  j:\n    runs-on: " + CONTRACT + "\n    steps:\n      - run: echo hi\n"
        )
        return [m for _, _, m in _problems(path, Recorded())]

    def test_the_shared_form_needs_a_boolean_light_input(self):
        self.assertEqual(self.check("boolean"), [])
        for light_input in ["string", None]:
            found = self.check(light_input)
            self.assertEqual(len(found), 1, light_input)
            self.assertIn("type boolean", found[0])


class Labels(unittest.TestCase):
    def test_contract_expression_is_accepted(self):
        self.assertEqual(lint.label_problems(CONTRACT), [])
        self.assertEqual(lint.label_problems(OWN), [])
        self.assertEqual(lint.label_problems(" " + CONTRACT.replace(" ", "\n  ") + "\n"), [])

    def test_anything_else_fails_and_shows_the_canonical_forms(self):
        label = "format('tankster-light-{0}-{1}', github.run_id, github.run_attempt)"
        for value in [
            "${{ (vars.CI_LIGHT_RUNNER == 'tankster-light') || " + label + " }}",
            "${{ vars.CI_LIGHT_RUNNER != 'tankster-light' && " + label + " || 'x' }}",
            "${{ " + label + " }}${{ vars.CI_LIGHT_RUNNER == 'tankster-light' }}",
            "${{ vars.CI_LIGHT_RUNNER == 'tankster-light' && " + label + " || vars.CI_RUNNER }}",
            "${{ vars.CI_LIGHT_RUNNER == 'tankster-light' && format('tankster-light-{0}-{1}', github.run_number, github.run_attempt) }}",
            "${{ vars.CI_LIGHT_RUNNER == 'tankster-light' && format('Tankster-Light-{0}-{1}', github.run_id, github.run_attempt) }}",
            "${{ vars.CI_LIGHT_RUNNER == 'tankster-light' && format('{0}-{1}-{2}', 'tankster-light', github.run_id, github.run_attempt) }}",
            CONTRACT.replace("'tankster-light-{0}", "'tankster -light-{0}"),
            [CONTRACT],
        ]:
            problems = lint.label_problems(value)
            self.assertEqual(len(problems), 1, value)
            self.assertIn(CONTRACT, problems[0])
            self.assertIn(OWN, problems[0])

    def test_non_light_values_are_ignored(self):
        self.assertEqual(lint.label_problems(OLD_REUSABLE), [])
        self.assertEqual(lint.label_problems(["self-hosted", "tankster-gcb"]), [])


class HttpResolver(unittest.TestCase):
    """The real fetch code against a local stand-in for the GitHub API."""

    @classmethod
    def setUpClass(cls):
        seen = cls.seen = []
        hits = cls.hits = {}

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802 - http.server's name
                seen.append((self.path, self.headers.get("Authorization"), self.headers.get("Accept")))
                repo = self.path.split("/")[3] if self.path.count("/") > 3 else ""
                hits[repo] = hits.get(repo, 0) + 1
                headers = {}
                if "/repos/o/node/contents/action.yml?ref=v1" in self.path:
                    body, code = b"runs:\n  using: node24\n", 200
                elif "/repos/o/yaml/contents/action.yaml?ref=abc" in self.path:
                    body, code = b"runs:\n  using: docker\n  image: x\n", 200
                elif repo == "flaky-once":
                    if hits[repo] == 1:
                        body, code = b"{}", 502
                    else:
                        body, code = b"runs:\n  using: docker\n", 200
                elif repo == "down":
                    body, code = b"{}", 503
                elif repo == "busy":
                    body, code, headers = b"{}", 429, {"Retry-After": "0"}
                elif repo == "limited":
                    body, code = b'{"message": "API rate limit exceeded"}', 403
                    headers = {"X-RateLimit-Remaining": "0"}
                elif repo == "denied":
                    body, code = b'{"message": "Resource not accessible by integration"}', 403
                else:
                    body, code = b'{"message": "Not Found"}', 404
                self.send_response(code)
                for key, value in headers.items():
                    self.send_header(key, value)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        cls.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.api = "http://127.0.0.1:{}".format(cls.server.server_address[1])

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(5)

    def resolver(self):
        return lint.Resolver(root=FIXTURES, api=self.api, token="t0ken", backoff=(0, 0))

    def test_reads_action_yml_with_token(self):
        data, reason = self.resolver().action("o/node@v1")
        self.assertIsNone(reason)
        self.assertEqual(data["runs"]["using"], "node24")
        path, auth, accept = self.seen[-1]
        self.assertEqual(auth, "Bearer t0ken")
        self.assertIn("raw", accept)

    def test_falls_back_to_action_yaml(self):
        self.assertEqual(lint.action_problems("o/yaml@abc", self.resolver()), ["o/yaml@abc is a Docker action (runs.using: docker)"])

    def test_not_found_fails_closed(self):
        resolver = self.resolver()
        problems = lint.action_problems("o/missing@v1", resolver)
        self.assertEqual(len(problems), 1)
        self.assertIn("could not read o/missing@v1", problems[0])
        self.assertIn("not found", problems[0])
        self.assertEqual(resolver.warnings, [])

    def test_refusal_fails_closed(self):
        problems = lint.action_problems("o/denied@v1", self.resolver())
        self.assertIn("HTTP 403", problems[0])

    def test_a_transient_error_is_retried(self):
        resolver = self.resolver()
        self.assertEqual(lint.action_problems("o/flaky-once@v1", resolver), ["o/flaky-once@v1 is a Docker action (runs.using: docker)"])
        self.assertEqual(self.hits["flaky-once"], 2)

    def test_transient_errors_warn_after_three_tries(self):
        for repo, why in [("down", "HTTP 503"), ("busy", "HTTP 429"), ("limited", "rate limited")]:
            resolver = self.resolver()
            self.hits[repo] = 0
            self.assertEqual(lint.action_problems("o/{}@v1".format(repo), resolver), [], repo)
            self.assertEqual(len(resolver.warnings), 1, repo)
            self.assertIn(why, resolver.warnings[0])
            self.assertEqual(self.hits[repo], 3, repo)

    def test_after_one_outage_the_rest_are_tried_once(self):
        resolver = self.resolver()
        self.hits["down"] = self.hits["busy"] = 0
        self.assertEqual(lint.action_problems("o/down@v1", resolver), [])
        self.assertEqual(lint.action_problems("o/busy@v1", resolver), [])
        self.assertEqual((self.hits["down"], self.hits["busy"]), (3, 1))
        self.assertEqual(len(resolver.warnings), 2)
        # A definite answer still counts while degraded.
        self.assertIn("not found", lint.action_problems("o/missing@v1", resolver)[0])

    def test_first_party_fallback_only_when_unreadable(self):
        self.assertEqual(lint.action_problems("actions/checkout@deadbeef", self.resolver()), [])
        self.assertTrue(lint.action_problems("actions/github-script@deadbeef", self.resolver()))

    def test_unreachable_api_warns(self):
        resolver = lint.Resolver(root=FIXTURES, api="http://127.0.0.1:9", token="", backoff=(0, 0))
        self.assertEqual(lint.action_problems("o/node@v1", resolver), [])
        self.assertIn("transient", resolver.warnings[0])

    def test_dockers_own_actions_need_no_lookup(self):
        resolver = self.resolver()
        before = len(self.seen)
        self.assertIn("Docker's own actions", lint.action_problems("docker/build-push-action@v7", resolver)[0])
        self.assertEqual(len(self.seen), before)

    def test_main_prints_the_warnings(self):
        out = io.StringIO()
        old = lint.Resolver
        api = self.api

        class Down(lint.Resolver):
            def __init__(self):
                super().__init__(root=FIXTURES, api=api, token="", backoff=(0, 0))

        path = _temp_yaml(
            "jobs:\n  j:\n    runs-on: " + OWN + "\n    steps:\n      - uses: o/down@v1\n"
        )
        lint.Resolver = Down
        try:
            with contextlib.redirect_stdout(out):
                code = lint.main([path])
        finally:
            lint.Resolver = old
        self.assertEqual(code, 0, out.getvalue())
        self.assertIn("::warning title=Light lane::could not read o/down@v1", out.getvalue())


class YqLoader(unittest.TestCase):
    """The yq v4 path the runners without PyYAML take."""

    def test_yq_path_matches_pyyaml(self):
        if lint._yq() is None:
            self.skipTest("yq v4 (mikefarah) not installed")
        with open(os.path.join(FIXTURES, "fail.yml"), encoding="utf-8") as handle:
            text = handle.read()
        saved = sys.modules.get("yaml")
        sys.modules["yaml"] = None  # makes `import yaml` raise ImportError
        try:
            via_yq = lint.load_yaml(text)
        finally:
            if saved is None:
                del sys.modules["yaml"]
            else:
                sys.modules["yaml"] = saved
        self.assertEqual(sorted(via_yq["jobs"]), sorted(re.findall(r"^  ([\w-]+): # expect:", text, re.M)))
        self.assertIn("tankster-light", via_yq["jobs"]["services"]["runs-on"])

    def test_no_parser_fails_closed(self):
        saved_mod = sys.modules.get("yaml")
        saved_which = lint.shutil.which
        sys.modules["yaml"] = None
        lint.shutil.which = lambda name: None
        try:
            with self.assertRaises(lint.LoadError):
                lint.load_yaml("a: 1\n")
        finally:
            lint.shutil.which = saved_which
            if saved_mod is None:
                del sys.modules["yaml"]
            else:
                sys.modules["yaml"] = saved_mod


def evaluate(expr, ctx):
    """Just enough of GitHub's expression language to evaluate runs-on: ||,
    &&, ==, parentheses, string literals, dotted names and format()."""
    tokens = []
    pos = [0]

    def peek():
        return tokens[pos[0]] if pos[0] < len(tokens) else None

    def take(want=None):
        tok = tokens[pos[0]]
        if want is not None and tok != want:
            raise ValueError("expected {} got {}".format(want, tok))
        pos[0] += 1
        return tok

    def truthy(v):
        return v not in (False, None, "", 0)

    def atom():
        tok = take()
        if tok == "(":
            v = or_()
            take(")")
            return v
        if tok.startswith("'"):
            return tok[1:-1].replace("''", "'")
        if tok == "format":
            take("(")
            args = [or_()]
            while peek() == ",":
                take(",")
                args.append(or_())
            take(")")
            return args[0].format(*[str(a) for a in args[1:]])
        return ctx.get(tok, "")

    def cmp_():
        v = atom()
        while peek() == "==":
            take("==")
            w = atom()
            v = str(v).lower() == str(w).lower()
        return v

    def and_():
        v = cmp_()
        while peek() == "&&":
            take("&&")
            w = cmp_()
            v = w if truthy(v) else v
        return v

    def or_():
        v = and_()
        while peek() == "||":
            take("||")
            w = and_()
            v = v if truthy(v) else w
        return v

    inner = expr.strip()
    assert inner.startswith("${{") and inner.endswith("}}"), expr
    tokens = re.findall(r"\|\||&&|==|\(|\)|,|'(?:[^']|'')*'|[A-Za-z_][\w.-]*", inner[3:-2])
    value = or_()
    assert pos[0] == len(tokens), "trailing tokens"
    return value


class ShippedWorkflows(unittest.TestCase):
    def load(self, name):
        with open(os.path.join(WORKFLOWS, name), encoding="utf-8") as handle:
            return lint.load_yaml(handle.read())

    def test_light_jobs_use_exactly_the_contract_expression(self):
        for name, jobs in LIGHT_WORKFLOWS.items():
            data = self.load(name)
            self.assertEqual(sorted(data["jobs"]), sorted(jobs), name)
            inputs = (data.get(True) or data.get("on"))["workflow_call"]["inputs"]
            default = name not in LIGHT_OFF_BY_DEFAULT
            self.assertEqual(inputs["light"], {**inputs["light"], "type": "boolean", "default": default}, name)
            self.assertIn("64 MiB", inputs["light"]["description"], name)
            if not default:
                self.assertIn("Off by default", inputs["light"]["description"], name)
            if name in NO_TOOLCHAIN_NOTE:
                self.assertIn("no C/C++ toolchain", inputs["light"]["description"], name)
            self.assertEqual(inputs["runs-on"]["default"], "", name)
            for job in jobs:
                self.assertEqual(data["jobs"][job]["runs-on"], CONTRACT, "{}: {}".format(name, job))

    def test_light_runners_never_save_a_cache(self):
        """Every cache save in a light job is switched off on the light runner
        (runner name crj-...), so no light job uploads one."""
        off = "!startsWith(runner.name, 'crj-')"
        for name, jobs in LIGHT_WORKFLOWS.items():
            data = self.load(name)
            for job in jobs:
                for step in data["jobs"][job].get("steps") or []:
                    uses = str(step.get("uses", ""))
                    with_ = step.get("with") or {}
                    where = "{}: {}: {}".format(name, job, step.get("name") or uses)
                    if uses.startswith("actions/cache@"):
                        self.fail(where + ": actions/cache saves; use restore and a gated save")
                    if uses.startswith("actions/cache/save@"):
                        self.assertIn(off, step.get("if", ""), where)
                    if uses.startswith("Swatinem/rust-cache@"):
                        self.assertIn(off, str(with_.get("save-if", "")), where)
                    if uses.startswith("actions/setup-go@"):
                        cache = str(with_.get("cache", "true")).lower()
                        self.assertTrue(cache == "false" or off in cache, where)
                    if uses.startswith("actions/setup-node@"):
                        self.assertIn(off, str(with_.get("package-manager-cache", "")), where)
                        if "cache" in with_:
                            self.assertIn(off, str(with_["cache"]), where)

    def test_light_jobs_pass_the_lint(self):
        for name in LIGHT_WORKFLOWS:
            found = _problems(os.path.join(WORKFLOWS, name), Summaries())
            self.assertEqual(found, [], "{}: {}".format(name, found))

    def test_other_workflows_are_not_light(self):
        for name in NOT_LIGHT:
            path = os.path.join(WORKFLOWS, name)
            self.assertTrue(os.path.isfile(path), "{} is missing: renamed? Update NOT_LIGHT".format(name))
            with open(path, encoding="utf-8") as handle:
                self.assertNotIn("tankster-light", handle.read(), name)

    def test_lane_closed_reduces_to_the_old_runner(self):
        """With CI_LIGHT_RUNNER unset, off or anything but tankster-light, the
        new expression gives what the old one gave, for every caller: with or
        without runs-on, light true or false, any CI_RUNNER."""
        for runs_on in ["", "ubuntu-24.04", "tankster-gcb", "self-hosted"]:
            for light in [True, False]:
                for ci_runner in ["", "tankster-gcb", "ubuntu-latest"]:
                    for lane in ["", "off", "OFF ", "on", "tankster-gcb", "tankster-light-1-1"]:
                        ctx = {
                            "inputs.runs-on": runs_on, "inputs.light": light,
                            "vars.CI_RUNNER": ci_runner, "vars.CI_LIGHT_RUNNER": lane,
                            "github.run_id": 987654321, "github.run_attempt": 2,
                        }
                        self.assertEqual(evaluate(CONTRACT, ctx), evaluate(OLD_REUSABLE, ctx), ctx)

    def test_lane_open(self):
        base = {"vars.CI_LIGHT_RUNNER": "tankster-light", "vars.CI_RUNNER": "tankster-gcb",
                "github.run_id": 987654321, "github.run_attempt": 2}
        self.assertEqual(evaluate(CONTRACT, {**base, "inputs.runs-on": "", "inputs.light": True}),
                         "tankster-light-987654321-2")
        self.assertEqual(evaluate(CONTRACT, {**base, "inputs.runs-on": "", "inputs.light": False}), "tankster-gcb")
        self.assertEqual(evaluate(CONTRACT, {**base, "inputs.runs-on": "x", "inputs.light": True}), "x")
        self.assertEqual(evaluate(CONTRACT, {**base, "vars.CI_RUNNER": "", "inputs.runs-on": "", "inputs.light": False}),
                         "ubuntu-latest")

    def test_plain_expression_in_the_readme(self):
        with open(os.path.join(ROOT, "README.md"), encoding="utf-8") as handle:
            readme = handle.read()
        plain = re.search(r"runs-on: (\$\{\{ \(vars\.CI_LIGHT_RUNNER.*?\}\})", readme)
        self.assertIsNotNone(plain, "README has no expression for repos' own jobs")
        self.assertEqual(lint.label_problems(plain.group(1)), [])
        for lane in ["", "off"]:
            for ci_runner in ["", "tankster-gcb"]:
                ctx = {"vars.CI_LIGHT_RUNNER": lane, "vars.CI_RUNNER": ci_runner}
                self.assertEqual(evaluate(plain.group(1), ctx), evaluate(OLD_PLAIN, ctx))
        self.assertIn(CONTRACT, readme.replace("\n", " "))


if __name__ == "__main__":
    unittest.main()
