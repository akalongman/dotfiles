"""Tests of forge.py and the inventory's forge stage.

forge.py names the forge and the project of a remote URL, reads the open
merge requests through `glab api` or `gh api`, and narrows them for --mine.

The cases that run the CLIs by name put fake glab and gh scripts first on
PATH and a failing stub of each behind them that records any call;
setUpClass stops the whole run when a fake cannot be written or does not
come first, and every such case confirms the stub was never hit. The other
cases pass a runner fake that refuses every glab and gh call it does not
answer and never hands one to the default runner. No case runs the real
glab or gh or reaches the network, and no case reads, prints or asserts on
the environment: they assert on the calls the fakes, the stub and the
runner record.
"""

import contextlib
import io
import json
import os
import shlex
import shutil
import sys
import tempfile
import unittest
from typing import Any
from unittest import mock

from scripts.unfinishedlib import cli, forge, model
from scripts.unfinishedlib.model import Item, MergeRequest
from tests import proc_fixture, repo_fixture

CLIS = ("glab", "gh")
GITLAB_PAGE = "projects/g%2Fsub%2Fr/merge_requests?state=opened&per_page=100&page="
GITHUB_PAGE = "repos/o/r/pulls?state=open&per_page=100&page="

# The fake CLI: logs its argv, then answers from answers.json (keyed by the
# JSON of its argv) or exits 97 for a call it was not told about.
FAKE_SOURCE = """\
import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
argv = [os.path.basename(sys.argv[1]), *sys.argv[2:]]
with open(os.path.join(here, "calls.jsonl"), "a", encoding="utf-8") as log:
    log.write(json.dumps(argv) + "\\n")
try:
    with open(os.path.join(here, "answers.json"), encoding="utf-8") as handle:
        answers = json.load(handle)
except OSError:
    answers = {}
answer = answers.get(json.dumps(argv))
if answer is None:
    sys.stderr.write("fake " + argv[0] + ": no answer for this call\\n")
    sys.exit(97)
sys.stdout.write(answer[1])
sys.stderr.write(answer[2])
sys.exit(answer[0])
"""


def gitlab_row(number: int, **overrides: Any) -> dict[str, Any]:
    row: dict[str, Any] = {
        "iid": number,
        "title": "Change " + str(number),
        "draft": False,
        "source_project_id": 42,
        "source_branch": "feature/" + str(number),
        "sha": format(number, "040x"),
        "target_branch": "main",
        "author": {"username": "someone"},
        "web_url": "https://gitlab.com/g/sub/r/-/merge_requests/" + str(number),
    }
    row.update(overrides)
    return row


def github_row(number: int, **overrides: Any) -> dict[str, Any]:
    row: dict[str, Any] = {
        "number": number,
        "title": "Change " + str(number),
        "draft": False,
        "head": {"ref": "feature/" + str(number), "sha": format(number, "040x"), "repo": {"full_name": "o/r"}},
        "base": {"ref": "main"},
        "user": {"login": "someone"},
        "html_url": "https://github.com/o/r/pull/" + str(number),
    }
    row.update(overrides)
    return row


class PathFakes(unittest.TestCase):
    """A base whose cases run glab and gh by name against the PATH fakes."""

    tmp = ""
    fakes = ""
    stub = ""
    path = ""

    @classmethod
    def setUpClass(cls) -> None:
        # SystemExit is not an Exception, so unittest lets it end the whole
        # run: no later case can reach a real glab or gh.
        original = os.environ.get("PATH", "")
        try:
            cls.tmp = os.path.realpath(tempfile.mkdtemp(prefix="unfinished-forge-"))
            cls.fakes = os.path.join(cls.tmp, "fakes")
            cls.stub = os.path.join(cls.tmp, "stub")
            cls.path = os.pathsep.join([cls.fakes, cls.stub, original])
            os.makedirs(cls.fakes)
            os.makedirs(cls.stub)
            source = os.path.join(cls.fakes, "fake.py")
            with open(source, "w", encoding="utf-8") as handle:
                handle.write(FAKE_SOURCE)
            stub_log = os.path.join(cls.stub, "calls.log")
            for name in CLIS:
                cls._script(
                    os.path.join(cls.fakes, name),
                    "exec " + shlex.quote(sys.executable) + " -I " + shlex.quote(source) + ' "$0" "$@"\n',
                )
                cls._script(
                    os.path.join(cls.stub, name),
                    "{ printf '%s' \"$0\"; printf ' %s' \"$@\"; printf '\\n'; } >> " + shlex.quote(stub_log) + "\nexit 99\n",
                )
        except OSError as exc:
            if cls.tmp:
                shutil.rmtree(cls.tmp, ignore_errors=True)
            raise SystemExit("test_forge: cannot write the fake glab and gh (" + str(exc) + "); stopping so the real CLIs never run") from None
        for name in CLIS:
            first = shutil.which(name, path=cls.path)
            behind = shutil.which(name, path=os.pathsep.join([cls.stub, original]))
            if first != os.path.join(cls.fakes, name) or behind != os.path.join(cls.stub, name):
                shutil.rmtree(cls.tmp, ignore_errors=True)
                raise SystemExit(
                    "test_forge: the fake " + name + " is not first on PATH, or its stub does not shadow the real one; "
                    "stopping so the real CLIs never run"
                )

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @staticmethod
    def _script(path: str, body: str) -> None:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\n" + body)
        os.chmod(path, 0o755)

    def setUp(self) -> None:
        for path in (os.path.join(self.fakes, "calls.jsonl"), os.path.join(self.stub, "calls.log")):
            with contextlib.suppress(FileNotFoundError):
                os.remove(path)
        self._answers: dict[str, list[Any]] = {}
        self._write_answers()
        patcher = mock.patch.dict(os.environ, {"PATH": self.path})
        patcher.start()
        self.addCleanup(patcher.stop)

    def _answer(self, argv: list[str], code: int, out: str, err: str = "") -> None:
        self._answers[json.dumps(argv)] = [code, out, err]
        self._write_answers()

    def _write_answers(self) -> None:
        with open(os.path.join(self.fakes, "answers.json"), "w", encoding="utf-8") as handle:
            json.dump(self._answers, handle)

    def _fake_calls(self) -> list[list[str]]:
        try:
            with open(os.path.join(self.fakes, "calls.jsonl"), encoding="utf-8") as handle:
                return [json.loads(line) for line in handle]
        except FileNotFoundError:
            return []

    def _assert_stub_never_hit(self) -> None:
        try:
            with open(os.path.join(self.stub, "calls.log"), encoding="utf-8") as handle:
                hits = handle.read().splitlines()
        except FileNotFoundError:
            hits = []
        self.assertEqual(hits, [], "the stub behind the fakes was called")


class ListOpenTest(PathFakes):
    def test_gitlab_pagination(self) -> None:
        first = [gitlab_row(number) for number in range(1, 101)]
        second = [gitlab_row(101), gitlab_row(102, source_project_id=7)]
        self._answer(["glab", "api", "--hostname", "gitlab.com", GITLAB_PAGE + "1"], 0, json.dumps(first))
        self._answer(["glab", "api", "--hostname", "gitlab.com", GITLAB_PAGE + "2"], 0, json.dumps(second))

        requests, error = forge.list_open("gitlab", "g/sub/r")

        self.assertIsNone(error)
        self.assertEqual(len(requests), 102)
        self.assertEqual([request.number for request in requests], list(range(1, 103)))
        self.assertTrue(all(isinstance(request.source_project, str) for request in requests))
        self.assertEqual((requests[0].source_project, requests[-1].source_project), ("42", "7"))
        self.assertEqual(
            requests[0],
            MergeRequest(
                number=1,
                title="Change 1",
                state="open",
                source_project="42",
                source_branch="feature/1",
                head_sha=format(1, "040x"),
                target_branch="main",
                author="someone",
                url="https://gitlab.com/g/sub/r/-/merge_requests/1",
            ),
        )
        self.assertEqual(
            self._fake_calls(),
            [
                ["glab", "api", "--hostname", "gitlab.com", GITLAB_PAGE + "1"],
                ["glab", "api", "--hostname", "gitlab.com", GITLAB_PAGE + "2"],
            ],
        )
        self._assert_stub_never_hit()

    def test_github_fields(self) -> None:
        rows = [
            github_row(5, draft=True, user={"login": "author-login"}),
            github_row(6, head={"ref": "fix/gone", "sha": "e" * 40, "repo": None}),
        ]
        self._answer(["gh", "api", "--hostname", "github.com", GITHUB_PAGE + "1"], 0, json.dumps(rows))

        requests, error = forge.list_open("github", "o/r")

        self.assertIsNone(error)
        self.assertEqual(
            requests[0],
            MergeRequest(
                number=5,
                title="Change 5",
                state="draft",
                source_project="o/r",
                source_branch="feature/5",
                head_sha=format(5, "040x"),
                target_branch="main",
                author="author-login",
                url="https://github.com/o/r/pull/5",
            ),
        )
        self.assertEqual((requests[1].state, requests[1].source_project, requests[1].source_branch), ("open", "", "fix/gone"))
        self.assertEqual(self._fake_calls(), [["gh", "api", "--hostname", "github.com", GITHUB_PAGE + "1"]])
        self._assert_stub_never_hit()

    def test_missing_credential_is_an_error_not_a_crash(self) -> None:
        self._answer(["glab", "api", "--hostname", "gitlab.com", GITLAB_PAGE + "1"], 1, "", "not logged in\nrun glab auth login\n")

        self.assertEqual(forge.list_open("gitlab", "g/sub/r"), ([], "glab: not logged in"))
        self._assert_stub_never_hit()

    def test_the_mine_arm_reads_through_the_cli_by_name(self) -> None:
        self._answer(["glab", "api", "--hostname", "gitlab.com", "user"], 0, json.dumps({"username": "me", "id": 9}))
        self._answer(["glab", "api", "--hostname", "gitlab.com", "projects/g%2Fsub%2Fr"], 0, json.dumps({"id": 42}))
        run = model.Run()

        kept = forge.mine_filter([_item(1, "42", "other"), _item(2, "7", "other")], "gitlab", "g/sub/r", run)

        self.assertEqual([item.attrs["number"] for item in kept], ["1"])
        self.assertEqual(run.errors, [])
        self.assertEqual(len(self._fake_calls()), 2)
        self._assert_stub_never_hit()


class RunnerFakeTest(unittest.TestCase):
    """Cases over a runner fake: the glab and gh calls it answers, and 127 for any other."""

    def setUp(self) -> None:
        self.calls: list[list[str]] = []

    def _runner(self, answers: dict[tuple[str, ...], tuple[int, str, str]]) -> model.Runner:
        def run(argv: list[str], cwd: str | None) -> tuple[int, str, str]:
            self.calls.append(list(argv))
            self.assertIsNone(cwd)
            answer = answers.get(tuple(argv))
            if answer is not None:
                return answer
            return 127, "", argv[0] + ": refused by the test runner"

        return run


class DetectAndProjectTest(unittest.TestCase):
    def test_detect(self) -> None:
        self.assertEqual(forge.detect("git@gitlab.com:g/r.git"), "gitlab")
        self.assertEqual(forge.detect("https://github.com/o/r"), "github")
        self.assertIsNone(forge.detect("ssh://host/x"))
        self.assertEqual(forge.detect("ssh://git@GitLab.com:22/g/r.git"), "gitlab")
        self.assertEqual(forge.detect("https://user:token@github.com/o/r.git"), "github")
        for other in ("https://gitlab.example.com/g/r", "/srv/git/r.git", "../r.git", "file:///srv/r.git", ""):
            with self.subTest(url=other):
                self.assertIsNone(forge.detect(other))

    def test_project_path(self) -> None:
        cases = {
            "git@gitlab.com:group/sub/project.git": "group/sub/project",
            "git@gitlab.com:g/r": "g/r",
            "ssh://git@gitlab.com:2222/g/r.git": "g/r",
            "ssh://gitlab.com/g/sub/r.git/": "g/sub/r",
            "https://user:token@github.com/o/r.git": "o/r",
            "https://github.com/o/r/": "o/r",
            "https://gitlab.com/g/sub/deeper/r": "g/sub/deeper/r",
        }
        for url, expected in cases.items():
            with self.subTest(url=url):
                self.assertEqual(forge.project_path(url), expected)
        for empty in ("https://github.com/", "git@gitlab.com:", "/srv/git/r.git"):
            with self.subTest(url=empty):
                self.assertIsNone(forge.project_path(empty))


class ListOpenErrorsTest(RunnerFakeTest):
    def test_error_prefix_rule(self) -> None:
        cases = [
            ((127, "", "gh: command not found"), "gh: command not found"),
            ((4, "", "\n  To get started, run gh auth login\n"), "gh: To get started, run gh auth login"),
            ((3, "", ""), "gh: exit 3"),
        ]
        for answer, expected in cases:
            with self.subTest(expected=expected):
                runner = self._runner({("gh", "api", "--hostname", "github.com", GITHUB_PAGE + "1"): answer})
                self.assertEqual(forge.list_open("github", "o/r", runner), ([], expected))

    def test_a_failing_later_page_keeps_the_earlier_pages(self) -> None:
        first = json.dumps([gitlab_row(number) for number in range(1, 101)])
        runner = self._runner(
            {
                ("glab", "api", "--hostname", "gitlab.com", GITLAB_PAGE + "1"): (0, first, ""),
                ("glab", "api", "--hostname", "gitlab.com", GITLAB_PAGE + "2"): (1, "", "glab: 502 Bad Gateway"),
            }
        )

        requests, error = forge.list_open("gitlab", "g/sub/r", runner=runner)

        self.assertEqual((len(requests), error), (100, "glab: 502 Bad Gateway"))

    def test_unexpected_output(self) -> None:
        full = json.dumps([gitlab_row(number) for number in range(1, 101)])
        missing = gitlab_row(101)
        del missing["target_branch"]
        cases = [
            ("not json", 0),
            (json.dumps({"message": "404 Not Found"}), 0),
            (json.dumps(["a", "b"]), 0),
            (json.dumps([gitlab_row(1, author="someone")]), 0),
            (json.dumps([gitlab_row(1, iid="1")]), 0),
            (json.dumps([missing]), 100),
        ]
        for out, kept in cases:
            with self.subTest(out=out[:40]):
                answers = {("glab", "api", "--hostname", "gitlab.com", GITLAB_PAGE + "1"): (0, out, "")}
                page = "1"
                if kept:
                    answers = {
                        ("glab", "api", "--hostname", "gitlab.com", GITLAB_PAGE + "1"): (0, full, ""),
                        ("glab", "api", "--hostname", "gitlab.com", GITLAB_PAGE + "2"): (0, out, ""),
                    }
                    page = "2"

                requests, error = forge.list_open("gitlab", "g/sub/r", self._runner(answers))

                self.assertEqual((len(requests), error), (kept, "glab: page " + page + ": unexpected output"))

    def test_a_row_repeated_across_pages_counts_once(self) -> None:
        first = json.dumps([gitlab_row(number) for number in range(2, 102)])
        second = json.dumps([gitlab_row(101), gitlab_row(1)])
        runner = self._runner(
            {
                ("glab", "api", "--hostname", "gitlab.com", GITLAB_PAGE + "1"): (0, first, ""),
                ("glab", "api", "--hostname", "gitlab.com", GITLAB_PAGE + "2"): (0, second, ""),
            }
        )

        requests, error = forge.list_open("gitlab", "g/sub/r", runner)

        self.assertIsNone(error)
        self.assertEqual(sorted(request.number for request in requests), list(range(1, 102)))

    def test_only_get_requests_are_made(self) -> None:
        runner = self._runner({("glab", "api", "--hostname", "gitlab.com", GITLAB_PAGE + "1"): (0, "[]", "")})
        forge.list_open("gitlab", "g/sub/r", runner)
        forge.mine_filter([_item(1, "42", "a")], "gitlab", "g/sub/r", model.Run(), runner=runner)
        refused = {"-f", "-F", "--field", "--raw-field", "--input", "--method", "-X", "--form", "--paginate"}

        self.assertEqual(len(self.calls), 2)
        for argv in self.calls:
            self.assertFalse(refused & set(argv), argv)


def _item(number: int, source_project: str, author: str) -> Item:
    return Item(
        kind="merge-request",
        title="!" + str(number) + " Change",
        certainty="certain",
        lines=[],
        paths=[],
        names=["feature/" + str(number)],
        date=None,
        sha=None,
        sessions=[],
        attrs={"number": str(number), "source_project": source_project, "author": author},
    )


class MineFilterTest(RunnerFakeTest):
    READS = {
        "gitlab": (("glab", "api", "--hostname", "gitlab.com", "user"), {"username": "me"}, ("glab", "api", "--hostname", "gitlab.com", "projects/g%2Fr"), {"id": 42}),
        "github": (("gh", "api", "--hostname", "github.com", "user"), {"login": "me"}, ("gh", "api", "--hostname", "github.com", "repos/g/r"), {"full_name": "g/r"}),
    }
    CANONICAL = {"gitlab": "42", "github": "g/r"}

    def test_mine_filter_keeps_the_canonical_project_and_the_logins_forks(self) -> None:
        for kind, (user_argv, user, project_argv, project) in self.READS.items():
            with self.subTest(kind=kind):
                self.calls = []
                runner = self._runner({user_argv: (0, json.dumps(user), ""), project_argv: (0, json.dumps(project), "")})
                items = [
                    _item(1, self.CANONICAL[kind], "other"),
                    _item(2, "fork/r", "me"),
                    _item(3, "fork/r", "other"),
                ]
                run = model.Run()

                kept = forge.mine_filter(items, kind, "g/r", run, runner=runner)

                self.assertEqual([item.attrs["number"] for item in kept], ["1", "2"])
                self.assertEqual((run.errors, run.complete), ([], True))
                self.assertEqual(self.calls, [list(user_argv), list(project_argv)])

    def test_a_failing_login_read_keeps_every_merge_request(self) -> None:
        user_argv, _, project_argv, project = self.READS["gitlab"]
        cases = [
            ({user_argv: (1, "", "not logged in")}, "glab: not logged in"),
            ({user_argv: (0, "[]", ""), project_argv: (0, json.dumps(project), "")}, "glab: user: unexpected output"),
            ({user_argv: (0, json.dumps({"username": "me"}), ""), project_argv: (1, "", "404 Not Found")}, "glab: 404 Not Found"),
        ]
        for answers, expected in cases:
            with self.subTest(expected=expected):
                items = [_item(1, "42", "other"), _item(2, "fork/r", "me"), _item(3, "fork/r", "other")]
                run = model.Run()

                kept = forge.mine_filter(items, "gitlab", "g/r", run, runner=self._runner(answers))

                self.assertEqual([item.attrs["number"] for item in kept], ["1", "2", "3"])
                self.assertEqual((run.errors, run.complete), ([expected], False))

    def test_no_merge_request_reads_nothing(self) -> None:
        run = model.Run()

        self.assertEqual(forge.mine_filter([], "gitlab", "g/r", run, runner=self._runner({})), [])
        self.assertEqual((self.calls, run.errors), ([], []))


class InventoryForgeStageTest(unittest.TestCase):
    """The forge stage of gather, through cli.main with --json over a fixture repository."""

    def setUp(self) -> None:
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="unfinished-forge-stage-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(os.path.join(self.home, ".claude", "projects"))
        self.proc = os.path.join(self.tmp, "proc")
        os.makedirs(self.proc)
        proc_fixture.make_proc(self.proc, 4242, "bash", "/", None, 100)
        self.calls: list[list[str]] = []

    def _repo(self, url: str | None) -> str:
        base = os.path.join(self.tmp, "repo")
        os.makedirs(base)
        work = repo_fixture.make_repo(base, with_origin=url is not None)["work"]
        if url is not None:
            repo_fixture.git(work, "remote", "set-url", "origin", url)
        return work

    def _main(self, work: str, answers: dict[tuple[str, ...], tuple[int, str, str]], *flags: str) -> tuple[int, dict[str, Any]]:
        def run(argv: list[str], cwd: str | None) -> tuple[int, str, str]:
            self.calls.append(list(argv))
            if argv[:1] == ["glab"] or argv[:1] == ["gh"]:
                return answers.get(tuple(argv), (127, "", argv[0] + ": refused by the test runner"))
            if argv[:1] == ["claude-sessions"]:
                return 127, "", "claude-sessions: command not found"
            return model.default_runner(argv, cwd)

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cli.main(["--json", "--root", work, *flags], home=self.home, proc_root=self.proc, runner=run, now=0.0)
        return code, json.loads(out.getvalue())

    def _forge_calls(self) -> list[list[str]]:
        return [argv for argv in self.calls if argv[:1] in (["glab"], ["gh"])]

    def test_a_remote_that_is_no_forge_is_skipped_without_its_userinfo(self) -> None:
        work = self._repo("https://deploy:s3cret-token@git.example.com/g/r.git")

        code, data = self._main(work, {}, "--forge")

        self.assertEqual(code, 0, data["meta"]["errors"])
        self.assertIn("forge: remote https://git.example.com/g/r.git is neither GitLab nor GitHub, skipped", data["meta"]["notes"])
        self.assertFalse(any("s3cret-token" in note or "deploy" in note for note in data["meta"]["notes"]))
        self.assertEqual((self._forge_calls(), data["merge_requests"]), ([], []))

    def test_no_remote_is_skipped(self) -> None:
        work = self._repo(None)

        code, data = self._main(work, {}, "--forge")

        self.assertEqual(code, 0, data["meta"]["errors"])
        self.assertIn("forge: no remote, skipped", data["meta"]["notes"])
        self.assertEqual((self._forge_calls(), data["merge_requests"]), ([], []))
        self.assertFalse(any("get-url" in argv for argv in self.calls))

    def test_without_forge_no_url_is_read_and_no_forge_is_called(self) -> None:
        work = self._repo("git@gitlab.com:g/r.git")

        code, data = self._main(work, {}, "--mine")

        self.assertEqual(code, 0, data["meta"]["errors"])
        self.assertFalse(any("get-url" in argv for argv in self.calls))
        self.assertEqual(self._forge_calls(), [])
        self.assertFalse(any(note.startswith("forge:") for note in data["meta"]["notes"]))

    def test_a_failing_list_is_an_error(self) -> None:
        work = self._repo("git@gitlab.com:g/r.git")

        code, data = self._main(work, {}, "--forge")

        self.assertEqual(code, 1)
        self.assertIs(data["meta"]["complete"], False)
        self.assertEqual(data["meta"]["errors"], ["glab: refused by the test runner"])
        self.assertEqual(
            self._forge_calls(),
            [["glab", "api", "--hostname", "gitlab.com", "projects/g%2Fr/merge_requests?state=opened&per_page=100&page=1"]],
        )

    def test_a_merge_request_branch_counts_for_segment_uniqueness(self) -> None:
        work = self._repo("git@gitlab.com:g/r.git")
        repo_fixture.git(work, "switch", "-q", "-c", "feature/fix")
        repo_fixture.commit(work, "fix.txt", "fix\n", "Add the fix")
        repo_fixture.git(work, "switch", "-q", "main")
        row = gitlab_row(4, source_branch="someone/fix", sha="4" * 40)
        page = ("glab", "api", "--hostname", "gitlab.com", "projects/g%2Fr/merge_requests?state=opened&per_page=100&page=1")

        code, data = self._main(work, {})
        self.assertEqual(code, 0, data["meta"]["errors"])
        self.assertIn("fix", self._tip_names(data, "feature/fix"))

        code, data = self._main(work, {page: (0, json.dumps([row]), "")}, "--forge")
        self.assertEqual(code, 0, data["meta"]["errors"])
        self.assertNotIn("fix", self._tip_names(data, "feature/fix"))
        self.assertEqual([item["names"] for item in data["merge_requests"]], [["someone/fix"]])

    @staticmethod
    def _tip_names(data: dict[str, Any], name: str) -> list[str]:
        tips = [tip for tip in data["tips"] if name in tip["names"]]
        assert len(tips) == 1, [tip["title"] for tip in data["tips"]]
        return list(tips[0]["names"])

    def test_forge_and_mine_keep_the_owners_merge_requests(self) -> None:
        work = self._repo("git@github.com:g/r.git")
        rows = [
            github_row(3, head={"ref": "fork-other", "sha": "3" * 40, "repo": {"full_name": "fork/r"}}),
            github_row(2, head={"ref": "fork-mine", "sha": "2" * 40, "repo": {"full_name": "fork/r"}}, user={"login": "me"}),
            github_row(1, head={"ref": "canonical", "sha": "1" * 40, "repo": {"full_name": "g/r"}}),
        ]
        answers = {
            ("gh", "api", "--hostname", "github.com", "repos/g/r/pulls?state=open&per_page=100&page=1"): (0, json.dumps(rows), ""),
            ("gh", "api", "--hostname", "github.com", "user"): (0, json.dumps({"login": "me"}), ""),
            ("gh", "api", "--hostname", "github.com", "repos/g/r"): (0, json.dumps({"full_name": "g/r"}), ""),
        }

        code, data = self._main(work, answers, "--forge", "--mine")

        self.assertEqual(code, 0, data["meta"]["errors"])
        self.assertEqual([item["title"] for item in data["merge_requests"]], ["!1 Change 1", "!2 Change 2"])
        self.assertEqual(len(self._forge_calls()), 3)

        self.calls = []
        code, data = self._main(work, answers, "--forge")

        self.assertEqual(code, 0, data["meta"]["errors"])
        self.assertEqual([item["title"] for item in data["merge_requests"]], ["!1 Change 1", "!2 Change 2", "!3 Change 3"])
        self.assertEqual(len(self._forge_calls()), 1)


if __name__ == "__main__":
    unittest.main()
