"""Trusted Linux PID1. Mount read-only; never copy into the agent workspace.

Protocol v1: host stages workspace, then creates /control/start as root. Host
reads trusted Docker stdout readiness (never agent stdout) before exec-reading
/control/status.json and archive.tar. The host
must impose a deadline and destroy the container on errors or missing status.
Requires a private PID namespace and only SETUID, SETGID, KILL capabilities.
Directory separation is not a security sandbox: Docker supplies the boundary.
"""

import json
import os
import signal
import stat
import shutil
import sys
import tarfile
import time


def provision():
    """Read only static, host-validated input. No agent exists during this phase."""
    if not os.path.isdir("/input"):
        return
    directories = []
    files = []
    def traversal_error(error):
        raise error
    for parent, names, leaves in os.walk("/input", followlinks=False,
                                        onerror=traversal_error):
        relative = os.path.relpath(parent, "/input")
        info = os.lstat(parent)
        if not stat.S_ISDIR(info.st_mode) or len(directories) >= 1024:
            raise RuntimeError("invalid input directory")
        directories.append((relative, stat.S_IMODE(info.st_mode) & 0o777))
        for name in names:
            if not stat.S_ISDIR(os.lstat(os.path.join(parent, name)).st_mode):
                raise RuntimeError("invalid input directory entry")
        for name in leaves:
            path = os.path.join(parent, name)
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or len(files) >= 1024:
                os.close(descriptor)
                raise RuntimeError("invalid input file or descriptor limit exceeded")
            files.append((os.path.relpath(path, "/input"), descriptor,
                          stat.S_IMODE(info.st_mode) & 0o777))
    copier = os.fork()
    if copier == 0:
        try:
            os.setgroups([])
            os.setgid(65534)
            os.setuid(65534)
            for relative, _ in directories:
                if relative != ".":
                    os.mkdir(os.path.join("/workspace", relative), 0o700)
            for relative, descriptor, mode in files:
                destination = os.path.join("/workspace", relative)
                with os.fdopen(descriptor, "rb") as source:
                    with open(destination, "xb") as output:
                        shutil.copyfileobj(source, output)
                os.chmod(destination, mode)
            for relative, mode in reversed(directories):
                os.chmod(os.path.join("/workspace", relative), mode)
        except BaseException:
            os._exit(1)
        os._exit(0)
    for _, descriptor, _ in files:
        os.close(descriptor)
    _, status = os.waitpid(copier, 0)
    if os.waitstatus_to_exitcode(status) != 0:
        raise RuntimeError("trusted input provisioning failed")


def main():
    if os.getpid() != 1 or os.getuid() != 0 or len(sys.argv) < 2:
        raise RuntimeError("supervisor requires root PID1 and an agent command")
    os.umask(0o077)
    provision()
    while not os.path.exists("/control/start"):
        time.sleep(0.01)
    child = os.fork()
    if child == 0:
        # Never let agent output reach Docker logs: only PID1 may publish the
        # readiness gate. The host MUST hard-quota /control tmpfs; output and
        # archive share that bound. Exhaustion prevents readiness publication.
        for descriptor, path in ((1, "/control/agent.stdout"),
                                 (2, "/control/agent.stderr")):
            output = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.dup2(output, descriptor)
            os.close(output)
        null = os.open("/dev/null", os.O_RDONLY)
        os.dup2(null, 0)
        os.close(null)
        os.setgroups([])
        os.setgid(65534)
        os.setuid(65534)
        os.chdir("/workspace")
        os.umask(0o022)
        os.execvp(sys.argv[1], sys.argv[1:])
    _, status = os.waitpid(child, 0)
    # Linux kill(-1) excludes the caller and namespace PID1. Unlike a process
    # group, this includes setsid descendants and double-forked orphans. KILL
    # is required because descendants have a different uid and may ignore TERM.
    # PID1 adopts every orphan. No export until all have actually exited and
    # been reaped (including processes holding workspace descriptors open).
    while True:
        try:
            os.kill(-1, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            break
        if pid == 0:
            time.sleep(0.005)
    remaining = [name for name in os.listdir("/proc")
                 if name.isdigit() and name != "1"]
    if remaining:
        raise RuntimeError("namespace is not quiescent: " + ",".join(remaining))
    # Export as the repository owner, not root: root deliberately lacks DAC
    # override. Open the protected destination before dropping identity.
    destination = os.open("/control/archive.tar", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    exporter = os.fork()
    if exporter == 0:
        try:
            os.setgroups([])
            os.setgid(65534)
            os.setuid(65534)
            with os.fdopen(destination, "wb") as output:
                with tarfile.open(fileobj=output, mode="w", dereference=False,
                                  format=tarfile.USTAR_FORMAT) as archive:
                    archive.add("/workspace", arcname=".")
        except BaseException:
            os._exit(1)
        os._exit(0)
    os.close(destination)
    _, export_status = os.waitpid(exporter, 0)
    if os.waitstatus_to_exitcode(export_status) != 0:
        raise RuntimeError("trusted workspace export failed")
    with open("/control/status.pending", "w") as output:
        json.dump({"protocol": 1, "exit_code": os.waitstatus_to_exitcode(status),
                   "quiescent": True}, output)
    os.rename("/control/status.pending", "/control/status.json")
    print(json.dumps({"protocol": 1, "quiescent": True}), flush=True)
    # Keep tmpfs alive for host export; do not launch any more agent code.
    while True:
        signal.pause()


if __name__ == "__main__":
    main()
