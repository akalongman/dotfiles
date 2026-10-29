"""A fake /proc tree for the tests, in the layout the kernel exposes.

make_proc writes one process directory <tmp>/<pid>/ holding comm, stat,
status, environ and the cwd symlink; tmp is the fake /proc root a case
passes in. The cwd target and the config directory are fixed strings that
no case reads from disk.
"""

import os


def make_proc(
    tmp: str,
    pid: int,
    comm: str,
    cwd: str,
    config_dir: str | None,
    starttime: int,
    *,
    with_stat: bool = True,
    uid: int | None = None,
) -> None:
    """Write <tmp>/<pid>/ for one process.

    comm ends in a newline, as the kernel writes it. stat is a full line of
    52 fields with the comm in parentheses and starttime in field 22; it is
    left out when with_stat is False, as for a process that exited between
    the listing and the read. status holds the kernel's lines from Name to
    Threads, each a key, a colon, a tab and the value; its Uid line gives
    uid (os.getuid() when None) as the real, effective, saved and
    filesystem uid, tab-separated, and its Gid line os.getgid() the same
    way. environ is NUL-separated and names CLAUDE_CONFIG_DIR only when
    config_dir is not None. cwd is a symlink to the given path.
    """
    folder = os.path.join(tmp, str(pid))
    os.makedirs(folder)
    with open(os.path.join(folder, "comm"), "w", encoding="utf-8") as handle:
        handle.write(comm + "\n")
    if with_stat:
        # Fields 3 to 21: state, ppid, pgrp, session, tty_nr, tpgid, flags,
        # four fault counts, four cpu times, priority, nice, num_threads,
        # itrealvalue; then starttime, vsize, rss, rsslim and 27 more.
        before = ["S", "1", str(pid), str(pid), "34817", str(pid), "4194560", "1027", "0", "0", "0"]
        before += ["312", "57", "0", "0", "20", "0", "11", "0"]
        after = ["1270415360", "61234", "18446744073709551615"] + ["0"] * 27
        fields = [str(pid), "(" + comm + ")", *before, str(starttime), *after]
        with open(os.path.join(folder, "stat"), "w", encoding="utf-8") as handle:
            handle.write(" ".join(fields) + "\n")
    uids = "\t".join([str(os.getuid() if uid is None else uid)] * 4)
    gids = "\t".join([str(os.getgid())] * 4)
    status = [
        ("Name", comm),
        ("Umask", "0022"),
        ("State", "S (sleeping)"),
        ("Tgid", str(pid)),
        ("Ngid", "0"),
        ("Pid", str(pid)),
        ("PPid", "1"),
        ("TracerPid", "0"),
        ("Uid", uids),
        ("Gid", gids),
        ("FDSize", "64"),
        ("Groups", str(os.getgid()) + " "),
        ("Threads", "11"),
    ]
    with open(os.path.join(folder, "status"), "w", encoding="utf-8") as handle:
        handle.write("".join(key + ":\t" + value + "\n" for key, value in status))
    environ = ["HOME=/home/u", "PATH=/usr/bin:/bin"]
    if config_dir is not None:
        environ.append("CLAUDE_CONFIG_DIR=" + config_dir)
    with open(os.path.join(folder, "environ"), "wb") as handle:
        handle.write("".join(entry + "\0" for entry in environ).encode("utf-8"))
    os.symlink(cwd, os.path.join(folder, "cwd"))
