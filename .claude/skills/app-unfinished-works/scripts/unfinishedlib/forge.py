"""Open and draft merge requests of the canonical remote's project, read-only.

detect names the forge a remote URL points at (GitLab or GitHub on their
public hosts), project_path the project it names, and list_open pages
through the project's open merge requests with `glab api` or `gh api`;
mine_filter narrows standalone merge-request items to the owner's for
--mine. Every call is a GET: no field, input or method flag is ever passed,
the host is named with --hostname (so neither GITLAB_HOST nor a default
repository picks another), and the project is named in the endpoint, never
through a placeholder that resolves from the CLI's own remote choice. A
failure is a returned or recorded line; nothing here raises on bad output.
"""

import json
import re
from typing import Any
from urllib.parse import quote, urlsplit

from scripts.unfinishedlib import model
from scripts.unfinishedlib.model import Item, MergeRequest, Run, Runner

# The forge of each host; a host is compared lowercased and whole.
HOSTS = {"gitlab.com": "gitlab", "github.com": "github"}
CLI = {"gitlab": "glab", "github": "gh"}
HOSTNAME = {"gitlab": "gitlab.com", "github": "github.com"}
PER_PAGE = 100
# A guard against a forge that never returns a short page.
MAX_PAGES = 1000
# The --mine reads: the login's field in `<cli> api user`, and the field of
# the project endpoint that merge requests name their source project by.
LOGIN_FIELD = {"gitlab": "username", "github": "login"}
PROJECT_FIELD = {"gitlab": "id", "github": "full_name"}

# git's scp-like remote syntax: [user@]host:path, a colon before any slash.
_SCP = re.compile(r"^(?:(?P<user>[^@/]*)@)?(?P<host>[^/:]+):(?P<path>.*)$")
# The authority of a URL, up to the first /, ? or #.
_AUTHORITY = re.compile(r"^(?P<authority>[^/?#]*)(?P<rest>.*)$", re.DOTALL)


def detect(remote_url: str) -> str | None:
    """gitlab for a gitlab.com host, github for github.com, else None."""
    split = _split(remote_url)
    return HOSTS.get(split[0]) if split is not None else None


def project_path(remote_url: str) -> str | None:
    """The project path a remote URL names: g/sub/r for git@host:g/sub/r.git.

    Reads the scp-like form `[user@]host:path`, `ssh://[user@]host[:port]/path`
    and `https://[userinfo@]host/path`: userinfo and port are dropped, the
    leading and trailing / and a trailing .git stripped, nested groups kept.
    None when the URL names no host or no path.
    """
    split = _split(remote_url)
    if split is None:
        return None
    path = split[1].strip("/")
    if path.endswith(".git"):
        path = path[: -len(".git")].rstrip("/")
    return path or None


def safe_url(remote_url: str) -> str:
    """The remote URL for display: userinfo (a user, a token) removed, query and fragment dropped."""
    url = remote_url.strip()
    if "://" in url:
        scheme, _, after = url.partition("://")
        match = _AUTHORITY.match(after)
        authority, rest = (match["authority"], match["rest"]) if match is not None else (after, "")
        rest = rest.split("?", 1)[0].split("#", 1)[0]
        return scheme + "://" + authority.rsplit("@", 1)[-1] + rest
    match = _SCP.match(url)
    if match is not None:
        return match["host"] + ":" + match["path"]
    return url


def list_open(kind: str, repo: str, runner: Runner = model.default_runner) -> tuple[list[MergeRequest], str | None]:
    """Every open and draft merge request of the project repo on the forge kind.

    kind is gitlab or github, repo the project path. Pages of 100 are read
    until a shorter one, with `glab api --hostname gitlab.com
    projects/<repo, every / as %2F>/merge_requests?state=opened&per_page=100&page=N`
    or `gh api --hostname github.com repos/<repo>/pulls?state=open&per_page=100&page=N`,
    cwd None. A number seen on an earlier page is not added again (a page
    can shift while it is read). Returns (requests, None), or the requests
    of the earlier pages and one line: `<cli>: <stderr first line>` for a
    non-zero exit (the line as it is when it already starts `<cli>: `,
    `<cli>: exit <n>` when stderr is empty), `<cli>: page <N>: unexpected
    output` for an exit 0 whose stdout is not a JSON array of objects
    carrying the mapped fields.
    """
    cli = CLI[kind]
    found: dict[int, MergeRequest] = {}
    for page in range(1, MAX_PAGES + 1):
        code, out, err = runner(_api(kind, _page_endpoint(kind, repo, page)), None)
        if code != 0:
            return list(found.values()), _failure(cli, err, code)
        rows = _rows(kind, out)
        if rows is None:
            return list(found.values()), cli + ": page " + str(page) + ": unexpected output"
        for request in rows:
            found.setdefault(request.number, request)
        if len(rows) < PER_PAGE:
            return list(found.values()), None
    return list(found.values()), cli + ": stopped after " + str(MAX_PAGES) + " pages of " + str(PER_PAGE)


def mine_filter(items: list[Item], kind: str, repo: str, run: Run, *, runner: Runner = model.default_runner) -> list[Item]:
    """The merge-request items --mine keeps: the canonical project's, and the forge login's.

    An item stays when its attrs source_project equals the canonical
    project (its GitLab id, its GitHub owner/name, read from the project
    endpoint) or its author equals the forge login (`<cli> api user`).
    Each is read once, and only when there is an item to judge; a read
    that fails is recorded in run.errors (complete False) and every item
    stays. Merge requests attached to a tip follow the tip's own arm.
    """
    if not items:
        return items
    login = _read_field(kind, "user", LOGIN_FIELD[kind], run, runner)
    if login is None:
        return items
    project = _read_field(kind, _project_endpoint(kind, repo), PROJECT_FIELD[kind], run, runner)
    if project is None:
        return items
    return [item for item in items if item.attrs.get("source_project") == project or item.attrs.get("author") == login]


def _split(remote_url: str) -> tuple[str, str] | None:
    """(lowercased host, path) of a URL or scp-like remote; None for a local path or no host."""
    url = remote_url.strip()
    if "://" in url:
        try:
            parts = urlsplit(url)
            host = parts.hostname
        except ValueError:
            return None
        return (host.lower(), parts.path) if host else None
    match = _SCP.match(url)
    if match is None:
        return None
    return match["host"].lower(), match["path"]


def _api(kind: str, endpoint: str) -> list[str]:
    return [CLI[kind], "api", "--hostname", HOSTNAME[kind], endpoint]


def _project_endpoint(kind: str, repo: str) -> str:
    if kind == "gitlab":
        return "projects/" + quote(repo, safe="")
    return "repos/" + quote(repo, safe="/")


def _page_endpoint(kind: str, repo: str, page: int) -> str:
    if kind == "gitlab":
        query = "/merge_requests?state=opened&per_page=" + str(PER_PAGE) + "&page=" + str(page)
    else:
        query = "/pulls?state=open&per_page=" + str(PER_PAGE) + "&page=" + str(page)
    return _project_endpoint(kind, repo) + query


def _failure(cli: str, err: str, code: int) -> str:
    """`<cli>: <stderr first line>`, the line itself when the CLI already prefixed it."""
    line = next((text.strip() for text in err.splitlines() if text.strip()), "")
    if not line:
        return cli + ": exit " + str(code)
    if line.startswith(cli + ": "):
        return line
    return cli + ": " + line


def _read_field(kind: str, endpoint: str, field: str, run: Run, runner: Runner) -> str | None:
    """One non-empty field of a JSON object a GET returns (an integer id as text); None after recording a failure."""
    cli = CLI[kind]
    code, out, err = runner(_api(kind, endpoint), None)
    if code != 0:
        _record(run, _failure(cli, err, code))
        return None
    try:
        data = json.loads(out)
    except ValueError:
        data = None
    value = data.get(field) if isinstance(data, dict) else None
    if field == "id" and _is_int(value):
        value = str(value)
    if not isinstance(value, str) or not value:
        _record(run, cli + ": " + endpoint + ": unexpected output")
        return None
    return value


def _rows(kind: str, out: str) -> list[MergeRequest] | None:
    """The page's merge requests, None when any row lacks a mapped field."""
    try:
        data = json.loads(out)
    except ValueError:
        return None
    if not isinstance(data, list):
        return None
    rows: list[MergeRequest] = []
    for raw in data:
        request = _gitlab(raw) if kind == "gitlab" else _github(raw)
        if request is None:
            return None
        rows.append(request)
    return rows


def _gitlab(raw: Any) -> MergeRequest | None:
    """One row of GitLab's merge request list; a null source project or sha reads as ""."""
    if not isinstance(raw, dict):
        return None
    author = raw.get("author")
    project = raw.get("source_project_id")
    sha = raw.get("sha")
    if not (
        _is_int(raw.get("iid"))
        and isinstance(raw.get("draft"), bool)
        and _texts(raw.get("title"), raw.get("source_branch"), raw.get("target_branch"), raw.get("web_url"))
        and (project is None or _is_int(project) or isinstance(project, str))
        and (sha is None or isinstance(sha, str))
        and isinstance(author, dict)
        and isinstance(author.get("username"), str)
    ):
        return None
    return MergeRequest(
        number=raw["iid"],
        title=raw["title"],
        state="draft" if raw["draft"] else "open",
        source_project="" if project is None else str(project),
        source_branch=raw["source_branch"],
        head_sha=sha or "",
        target_branch=raw["target_branch"],
        author=author["username"],
        url=raw["web_url"],
    )


def _github(raw: Any) -> MergeRequest | None:
    """One row of GitHub's pull request list; a deleted head repository reads as ""."""
    if not isinstance(raw, dict):
        return None
    head, base, user = raw.get("head"), raw.get("base"), raw.get("user")
    if not (isinstance(head, dict) and isinstance(base, dict) and isinstance(user, dict)):
        return None
    repo = head.get("repo")
    if not (
        _is_int(raw.get("number"))
        and isinstance(raw.get("draft"), bool)
        and _texts(raw.get("title"), raw.get("html_url"), head.get("ref"), head.get("sha"), base.get("ref"), user.get("login"))
        and (repo is None or (isinstance(repo, dict) and isinstance(repo.get("full_name"), str)))
    ):
        return None
    return MergeRequest(
        number=raw["number"],
        title=raw["title"],
        state="draft" if raw["draft"] else "open",
        source_project=repo["full_name"] if repo is not None else "",
        source_branch=head["ref"],
        head_sha=head["sha"],
        target_branch=base["ref"],
        author=user["login"],
        url=raw["html_url"],
    )


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _texts(*values: Any) -> bool:
    return all(isinstance(value, str) for value in values)


def _record(run: Run, line: str) -> None:
    run.errors.append(line)
    run.complete = False
