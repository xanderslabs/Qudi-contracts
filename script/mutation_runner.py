#!/usr/bin/env python3
"""The mutation gate.

Reads mutation/catalogue.json (one entry per bound in the money closure). For every entry
whose status is "catalogued": apply its mutation to the source file, run the full test suite,
and check three conditions in order:

  1. Baseline green. Checked once, before any mutation runs. If the suite is not green on the
     clean tree, the run refuses outright: a red baseline would report every entry "killed" for
     nothing.
  2. The mutant compiles (the suite actually ran). A mutation that produces uncompiling Solidity
     exits non-zero with zero tests run; that is not a kill, it is an ERROR, and is reported and
     counted separately.
  3. The suite goes red. Only if 1 and 2 both hold does a non-zero exit count as a kill.

An ERROR (condition 2 failing, or the catalogued match text not found exactly once) is recorded
against that entry and the run continues to the next one: one drifted
entry no longer hides the state of the other 88.

OPERATIONAL NOTE, READ THIS FIRST
---------------------------------
This tool DELETES CODE FROM TRACKED SOURCE FILES IN PLACE, one bound at a time, and puts it
back afterwards. Three things follow, and anyone reaching for it at speed should know all three
before they start it.

  * It runs in its OWN `git worktree`, which it creates. A mutation is never applied to
    the tree you or another session are working in. If it cannot get that worktree it refuses
    and says why. You do not have to arrange this; you cannot opt out of it either.
  * It requires a CLEAN tree in the repository you invoke it from. A stray edit would otherwise
    sit inside every mutation's before and after state alike, and the worktree is cut at HEAD,
    so uncommitted work would not be what got tested.
  * After ANY abnormal exit, the next run REPAIRS and then REFUSES. It leaves a sentinel on disk
    before each mutation, finds it on the next start, restores the file from it, tells you what
    it restored, and exits non-zero. Run it once more and it proceeds. That is the design, not a
    fault: a repair you were not told about is how a deleted money bound reaches a commit.

Restores the mutated file on every exit path, including a signal: SIGTERM,
SIGHUP and SIGQUIT are all handled, re-raising as a normal Python exception so the existing
try/finally still runs. SIGINT already works through Python's own default SIGINT ->
KeyboardInterrupt behavior.

SIGKILL cannot be handled by any process, and that is still true. What changed is that being unable to TRAP a signal is not the same as being
unable to repair its CONSEQUENCE. The sentinel above is written before the mutation and removed
only after the restore has been verified, so a SIGKILL, an OOM kill, a container stop escalation
and a power cut all leave a record on disk that the next start acts on. Twice now a killed run
has left a money bound deleted in a working tree, once in a contract the task was not even
touching, which is what this exists to stop.

Entries whose status is "redundant" carry a recorded proof in the catalogue instead of a test.
The runner does not mutate them; it reports them as skipped so they stay visible.

Refuses to run against a dirty git tree (the whole repository), since a
stray edit sitting in the working copy would be silently included in every mutation's "before"
and "after" state alike.

Usage: python3 script/mutation_runner.py [--only ID [ID ...]] [--fuzz-seed SEED]
Run from the repository root (or pass --root).

Logs are line-buffered whether or not stdout is a terminal, so a run that is killed after hours
still has everything it printed up to the kill on disk. Do not pass `-u`; it is not needed and
relying on the caller to remember it is how a three-hour run produced a zero-byte log.
"""
import argparse
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
# `Optional` rather than `str | None`: this runs on the system python, 3.9 here, where a PEP 604
# `X | None` in an evaluated annotation raises TypeError at import.
from typing import Optional

# Python block-buffers stdout when it is not a terminal, so a run
# redirected to a file and then killed loses whatever was still in the buffer. A three-hour gate
# run produced a zero-byte log that way, which is exactly the run whose log mattered. Line
# buffering is set here rather than left to the caller remembering `-u`, because the caller
# forgetting is the failure being fixed. `reconfigure` is a no-op-if-unsupported best effort so a
# non-TextIOWrapper stream (a pytest capture, say) cannot stop the tool from running.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(line_buffering=True)
    except (AttributeError, ValueError):  # pragma: no cover
        pass

# The mutation gate pins a seed so its baseline is reproducible and a red
# baseline cannot arrive by luck. This is the regression corpus's first entry
# (mutation/regression-seeds.json), which now passes under the rewritten
# invariant_feeSharesMatchSplit. Override with --fuzz-seed for local experiments; CI does not.
DEFAULT_FUZZ_SEED = "0x328259ab689b1f44f21fb11f07052bbc9dda6072a50f730065f318a9aceade52"

RAN_SUMMARY_RE = re.compile(r"Ran \d+ test suites? in")


class _Terminated(Exception):
    """Raised by the signal handler so the normal try/finally cleanup still runs."""


# SIGTERM (a cancelled CI job, a plain `kill`), SIGHUP (a closed terminal or dead ssh session,
# the common case for a long local run) and SIGQUIT all terminate a process by default with no
# unwinding, so `finally` never runs unless a handler intercepts them. SIGINT already unwinds
# through Python's own default handler, which raises KeyboardInterrupt; nothing to install for
# it, only to confirm. SIGKILL cannot be
# caught by any process.
_HANDLED_SIGNALS = (signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT)


def _install_signal_handler():
    def _handler(signum, frame):
        raise _Terminated(f"terminated by signal {signum}")

    for sig in _HANDLED_SIGNALS:
        signal.signal(sig, _handler)


def _git(args: list[str], cwd: Path, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=check)


def state_dir_for(repo_root: Path) -> Path:
    """Where this runner keeps the things that have to outlive the process: its worktree and its
    sentinel.

    Outside the repository on purpose. Inside it, the sentinel would itself make the tree dirty
    and the runner would refuse to start because of its own state file. Deterministic per
    repository path, so a crashed run's leftovers are found again by the next start rather than
    stranded under a fresh temp name. Under the state home rather than /tmp so a reboot does not
    take the evidence with it: a machine that was power-cycled mid-mutation is precisely when the
    sentinel has to still be there."""
    base = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state")
    key = hashlib.sha1(str(repo_root).encode()).hexdigest()[:12]
    return base / "qudi-mutation-gate" / f"{repo_root.name}-{key}"


def _fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_sentinel(sentinel: Path, entry_id: str, rel_path: str, worktree: Path, original: str) -> None:
    """Records, BEFORE the mutation is applied, which file is about to be changed and every byte
    it currently holds.

    Durability is the whole point, so this is not a plain write. The bytes go to a temp file, are
    fsynced, are moved into place with `os.replace` (atomic within a directory), and the directory
    entry is fsynced too. Without the fsyncs a power cut could leave the mutation on disk and the
    sentinel not, which is the one ordering this must never produce."""
    sentinel.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema": 1,
        "entry_id": entry_id,
        "file": rel_path,
        "worktree": str(worktree),
        "written_at": datetime.now(timezone.utc).isoformat(),
        "pid": os.getpid(),
        "original": original,
    }
    tmp = sentinel.with_suffix(".tmp")
    with open(tmp, "w") as fh:
        json.dump(payload, fh)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, sentinel)
    _fsync_dir(sentinel.parent)


def clear_sentinel(sentinel: Path, target: Path, original: str) -> str:
    """Removes the sentinel, but only after confirming the file on disk is byte-for-byte the
    original it recorded. Returns an error string if it is not, in which case the sentinel is
    deliberately left in place so the next start repairs it.

    This is the second half of the ordering: the sentinel outliving a successful restore is
    harmless (the next start redoes a restore that changes nothing), while the sentinel
    disappearing before the restore is verified would lose the only record that a file was
    touched."""
    try:
        on_disk = target.read_text()
    except OSError as exc:
        return f"could not read {target} back to verify the restore: {exc}"
    if on_disk != original:
        return (
            f"the restore of {target} did not match the bytes the sentinel recorded. The sentinel "
            f"is being kept so the next run repairs it."
        )
    sentinel.unlink(missing_ok=True)
    _fsync_dir(sentinel.parent)
    return ""


def recover_sentinel(sentinel: Path) -> tuple[bool, list[str]]:
    """Startup repair. Returns (found, lines_to_report).

    A sentinel on disk means a previous run did not finish: it is written before every mutation
    and removed only after that mutation has been put back and the restore verified. Three states
    reach here and all three are handled the same way, by writing the recorded bytes back:

      * died between writing the sentinel and mutating: the file already holds the original, so
        the restore changes nothing. An unnecessary restore, which is the safe direction.
      * died while mutated: the file holds the mutant and the restore is the point of all this.
      * died between restoring and removing the sentinel: the file already holds the original
        again, so the restore changes nothing. Unnecessary again, safe again.

    The runner cannot tell the three apart and does not try. It cannot, either: the only thing it
    knows is which bytes belong in the file, and writing them is correct in every case."""
    if not sentinel.exists():
        return False, []
    lines = []
    try:
        data = json.loads(sentinel.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        return True, [
            f"A sentinel exists at {sentinel} but could not be read ({exc}).",
            "It is NOT being removed. A previous run died while a mutation may have been applied,",
            "and this runner will not guess. Inspect the worktree by hand before continuing.",
        ]
    worktree = Path(data["worktree"])
    target = worktree / data["file"]
    lines.append("A PREVIOUS RUN DIED. A sentinel was on disk, which means it was killed by")
    lines.append("something it could not trap: SIGKILL, an OOM kill, a container stop, or a power")
    lines.append("cut. The file it was mutating is being restored from the bytes the sentinel")
    lines.append("recorded before the mutation was applied.")
    lines.append("")
    lines.append(f"  sentinel:   {sentinel}")
    lines.append(f"  entry:      {data['entry_id']}")
    lines.append(f"  file:       {target}")
    lines.append(f"  written at: {data['written_at']} by pid {data['pid']}")
    if not target.exists():
        lines.append("")
        lines.append(f"REFUSED: {target} does not exist, so there is nothing to restore it into.")
        lines.append("The sentinel is being kept. Inspect by hand.")
        return True, lines
    before = target.read_text()
    already = before == data["original"]
    _atomic_write(target, data["original"])
    err = clear_sentinel(sentinel, target, data["original"])
    lines.append("")
    if already:
        lines.append("RESTORED: the file already held the original bytes, so nothing changed on")
        lines.append("disk. That is one of the two windows where the sentinel outlives the thing it")
        lines.append("was guarding, and an unnecessary restore is the direction this fails in.")
    else:
        lines.append("RESTORED: the file held a mutant and now holds the original bytes again.")
        lines.append("Had this gone uncaught, a deleted bound would have been sitting in a working")
        lines.append("tree next to whatever anyone committed next.")
    if err:
        lines.append("")
        lines.append(f"WARNING: {err}")
    else:
        lines.append("The sentinel has been removed.")
    return True, lines


def ensure_worktree(repo_root: Path, state_dir: Path) -> tuple[Path, list[str], str]:
    """Creates, or re-uses, the worktree this runner owns. Returns (worktree, notes, error).

    The gate runs in an isolated worktree, always, and the runner enforces that
    rather than trusting the caller to remember. A mutation applied to the tree a person or
    another session is working in is how a deleted money bound ends up in someone else's commit,
    which has now happened twice.

    The worktree is detached at the invoking tree's HEAD. Detached rather than on the branch,
    because git refuses to check the same branch out twice and the caller is already on it."""
    worktree = state_dir / "worktree"
    head = _git(["rev-parse", "HEAD"], repo_root).stdout.strip()
    notes = []

    registered = False
    for line in _git(["worktree", "list", "--porcelain"], repo_root).stdout.splitlines():
        if line.startswith("worktree ") and Path(line[len("worktree "):]).resolve() == worktree:
            registered = True
            break

    if worktree.exists() and not registered:
        return worktree, notes, (
            f"{worktree} exists but is not a registered worktree of this repository. It is not "
            f"being deleted: this runner cannot prove what is in it. Remove it by hand, or run "
            f"`git -C {repo_root} worktree prune`, then try again."
        )

    if registered:
        notes.append(f"Re-using the worktree a previous run left at {worktree}.")
        dirty = git_dirty(worktree)
        if dirty.strip():
            return worktree, notes, (
                "the worktree is dirty and no sentinel explained it. That means an edit in there "
                "did not come from this runner's mutation path, so it is not being discarded. "
                f"Inspect it, then clean it with `git -C {worktree} checkout -- .` and try "
                f"again.\n{dirty}"
            )
        out = _git(["checkout", "--detach", head], worktree, check=False)
        if out.returncode != 0:
            return worktree, notes, f"could not move the worktree to HEAD ({head[:12]}): {out.stderr.strip()}"
    else:
        state_dir.mkdir(parents=True, exist_ok=True)
        out = _git(["worktree", "add", "--detach", str(worktree), head], repo_root, check=False)
        if out.returncode != 0:
            return worktree, notes, f"could not create a worktree at {worktree}: {out.stderr.strip()}"
        notes.append(f"Created an isolated worktree at {worktree}, detached at {head[:12]}.")
    return worktree, notes, ""


def git_root(start: Path) -> Path:
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=start, capture_output=True, text=True, check=True,
    )
    return Path(out.stdout.strip())


def git_dirty(repo_root: Path) -> str:
    """Checks the WHOLE repository, not just a subdirectory (an older check was scoped to one
    subdirectory while its own message claimed the working tree in general)."""
    out = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=repo_root, capture_output=True, text=True, check=True,
    )
    return out.stdout


class _ToolMissing(Exception):
    """Raised when `forge` itself cannot be found, so main() can report it cleanly instead of a
    bare traceback."""


def run_tests(root: Path, fuzz_seed: str, match_test: Optional[str] = None) -> tuple[bool, bool, str]:
    """Runs the suite. Returns (ran, green, tail_of_output).

    `ran` is whether forge actually executed the suite (its own summary line appears), as
    opposed to failing to compile. `green` is only meaningful when `ran` is True.

    With `match_test`, runs only that test. **A red narrow run is a kill on the same terms as a
    red full run**: the mutation made a test fail, which is the definition. A GREEN narrow run
    decides nothing and the caller must escalate to the full suite, because the bound may be
    covered by a test other than the one the catalogue names. That asymmetry is what makes this
    safe: no survivor can be reported without a full run having gone green.

    Measured 2026-09-22: a warm full suite is about 17s and a single test about 0.25s, against
    10.2s of recompilation that every mutation pays either way.

    Raises `_ToolMissing` if `forge` itself cannot be found on PATH."""
    cmd = ["forge", "test", "-j", "4", "--fuzz-seed", fuzz_seed]
    if match_test:
        # A `test` field may name SEVERAL tests, comma separated: 37 of 147 do. Each becomes an
        # alternative, so the narrow run covers all of them and a red in any one is the kill.
        # Treating the whole string as a single name is what made those 37 never match.
        #
        # Anchored `^name\(` and not `^name$`: forge matches against the test's SIGNATURE, so the
        # string is `name()` or `name(uint256,...)` for a fuzz test and a trailing `$` never
        # matches. Getting this wrong made every narrow run report "no tests found", which the
        # caller reads as "did not run" and escalates, so it was slow rather than wrong.
        names = [n.strip() for n in match_test.split(",") if n.strip()]
        alternation = "|".join(re.escape(n) for n in names)
        cmd += ["--match-test", f"^({alternation})\\("]
    try:
        proc = subprocess.run(
            cmd,
            cwd=root, capture_output=True, text=True,
        )
    except FileNotFoundError as exc:
        raise _ToolMissing(f"could not run forge: {exc}") from exc
    output = proc.stdout + proc.stderr
    tail = "\n".join(output.splitlines()[-15:])
    ran = bool(RAN_SUMMARY_RE.search(output))
    # A signal or OOM kill landing on the forge child after
    # it prints its summary line but before it exits 0 leaves `ran=True` with a negative
    # (signal) returncode, which `green = ran and returncode == 0` already reads as "not green"
    # and therefore "killed" -- a kill the mutation did not actually earn. A negative returncode
    # means the child died by a signal, not a test failure, so it is never ran+green here, but
    # the caller must not read it as ran+red (a kill) either; treated as `ran=False` forces the
    # caller's own "the suite never ran" ERROR path instead of a false kill.
    if proc.returncode is not None and proc.returncode < 0:
        ran = False
    green = ran and proc.returncode == 0
    return ran, green, tail


def _atomic_write(path: Path, text: str) -> None:
    """Writes via a temp file plus `os.replace` rather than truncating `path` in place, so a
    signal landing mid-write either lands before the replace (the original file is untouched) or
    after it (the new content is fully in place), never on a half-written target. Does not close the SIGKILL window, which no userspace fix can."""
    tmp = path.with_suffix(path.suffix + ".mutation-tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def apply_mutation(path: Path, match: str, mutant: str) -> tuple[str, str]:
    """Replaces the unique occurrence of `match` with `mutant`. Returns (original_text, error).
    `error` is empty on success; otherwise `original_text` is empty and the file was not
    touched. Does not raise: a drifted match is reported and stepped over, not a run-aborting
    exception."""
    original = path.read_text()
    count = original.count(match)
    if count != 1:
        return "", (
            f"expected exactly one occurrence of the catalogued match text in {path}, found "
            f"{count} (the catalogue has drifted from the source; update the entry's match text)"
        )
    _atomic_write(path, original.replace(match, mutant, 1))
    return original, ""


def main() -> int:
    _install_signal_handler()

    parser = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=(
            "The mutation gate. Deletes one catalogued bound at a time from tracked "
            "source, runs the full test suite, and requires the suite to go red."
        ),
        epilog=(
            "WHAT THIS DOES TO YOUR FILES\n"
            "  It mutates tracked source files in place. It does that inside its OWN git worktree,\n"
            "  which it creates and owns, so a mutation is never applied to the tree you or\n"
            "  another session are working in. If it cannot get that worktree it refuses and says why.\n"
            "\n"
            "  It requires the repository you invoke it from to be CLEAN. The worktree is cut at HEAD,\n"
            "  so uncommitted work is not what would get tested, and a stray edit would sit inside\n"
            "  every mutation's before and after state alike.\n"
            "\n"
            "AFTER AN ABNORMAL EXIT\n"
            "  A sentinel is written before each mutation and removed only once the file has been put\n"
            "  back and the restore verified. If a run is killed by something it cannot trap (SIGKILL,\n"
            "  an OOM kill, a container stop, a power cut), the next run finds that sentinel, RESTORES\n"
            "  the file, tells you what it restored, and REFUSES to go on. Run it once more and it\n"
            "  proceeds. Being told is the point: twice now a killed run has left a money bound\n"
            "  deleted in a working tree, once in a contract the task was not even touching.\n"
            "\n"
            "  Logs are line-buffered whether or not stdout is a terminal, so a killed run keeps\n"
            "  everything it printed. Do not pass -u.\n"
        ),
    )
    parser.add_argument("--root", default=".", help="repository root (default: cwd)")
    parser.add_argument("--only", nargs="*", default=None, help="run only these catalogue ids")
    parser.add_argument("--catalogue", default=None, help="path to catalogue.json (default: <root>/mutation/catalogue.json)")
    parser.add_argument("--fuzz-seed", default=DEFAULT_FUZZ_SEED, help="pinned --fuzz-seed forwarded to every forge test invocation")
    args = parser.parse_args()

    caller_root = Path(args.root).resolve()
    caller_repo = git_root(caller_root)
    rel_root = caller_root.relative_to(caller_repo)
    state_dir = state_dir_for(caller_repo)
    sentinel = state_dir / "sentinel.json"

    # Startup repair comes FIRST, before the dirty check and before any worktree work. A sentinel
    # on disk is the one thing that must be acted on whatever else is true, and the repair has to
    # be reported rather than folded silently into a later step.
    found, lines = recover_sentinel(sentinel)
    if found:
        for line in lines:
            print(line)
        print()
        print("REFUSED to continue in the same run that performed a repair. Nothing was mutated.")
        print("Re-run the same command and it will proceed from a tree it has just confirmed.")
        return 2

    dirty = git_dirty(caller_repo)
    if dirty.strip():
        print("REFUSED: the working tree is not clean (checked from the repository root). The")
        print("mutation gate never runs against a dirty tree: the worktree it tests in is cut at")
        print("HEAD, so uncommitted work is not what would get tested, and a stray edit would sit")
        print("inside every mutation's before/after state alike.")
        print(dirty)
        return 2

    # The gate runs in an isolated worktree, always, and the runner is what
    # enforces it.
    worktree, notes, wt_error = ensure_worktree(caller_repo, state_dir)
    for note in notes:
        print(note)
    if wt_error:
        print(f"REFUSED: {wt_error}")
        print("Nothing was mutated. The tree you invoked this from has not been touched.")
        return 2
    repo_root = worktree
    root = worktree / rel_root
    print(f"Mutating inside {root}, never {caller_root}.")
    print()

    catalogue_path = Path(args.catalogue).resolve() if args.catalogue else root / "mutation" / "catalogue.json"
    entries = json.loads(catalogue_path.read_text())
    if args.only:
        wanted = set(args.only)
        entries = [e for e in entries if e["id"] in wanted]
        missing = wanted - {e["id"] for e in entries}
        if missing:
            print(f"REFUSED: unknown catalogue id(s): {sorted(missing)}")
            return 2

    # Condition 1: baseline green, checked once, before any mutation runs.
    try:
        baseline_ran, baseline_green, baseline_tail = run_tests(root, args.fuzz_seed)
    except _ToolMissing as exc:
        print(f"REFUSED: {exc}. Nothing was mutated.")
        return 2
    if not baseline_ran:
        print("REFUSED: the suite did not even run on the clean tree (a compile failure before")
        print("any mutation). Nothing can be shown to have caused a failure.")
        print(baseline_tail)
        return 2
    if not baseline_green:
        print("REFUSED: the suite is already red on the clean tree, so no mutation can be shown")
        print("to have caused a failure.")
        print(baseline_tail)
        return 2

    killed, survived, skipped, errors = [], [], [], []
    # Narrow-first accounting, printed with the summary so the saving is visible and a catalogue
    # drifting away from its `test` fields shows up as the hit rate falling.
    narrowed_attempted = narrowed_hit = 0

    for entry in entries:
        eid = entry["id"]
        if entry["status"] == "redundant":
            skipped.append(entry)
            print(f"[{eid}] SKIPPED (redundant, proof recorded): {entry['function']}: {entry['bound']}")
            continue

        target = root / entry["file"]
        print(f"[{eid}] mutating {entry['file']}: {entry['function']}: {entry['bound']}")
        original = None
        pre_mutation = None
        try:
            # The sentinel goes down BEFORE the mutation, holding the file's current bytes. If the
            # process dies between these two statements the next start restores bytes the file
            # already has, which changes nothing; that is the window failing toward an unnecessary
            # restore rather than a missed one.
            pre_mutation = target.read_text()
            # Recorded relative to the WORKTREE ROOT, not to the catalogue's own root-relative
            # paths, because that is what recovery resolves it against on the next start.
            # Getting this wrong is how the first version of this code produced a sentinel whose
            # file it could not find; the recovery path refused and kept the sentinel rather than
            # guessing, which is the direction it should fail in, but it still could not repair.
            write_sentinel(sentinel, eid, str(target.relative_to(worktree)), worktree, pre_mutation)
            original, drift_error = apply_mutation(target, entry["match"], entry["mutant"])
            if drift_error:
                errors.append((entry, drift_error))
                print(f"[{eid}] ERROR: {drift_error}. This is not a kill.")
                continue

            # Conditions 2 and 3: the mutant must compile, and only then does a
            # red suite count as a kill.
            #
            # Narrow-first since 2026-09-22. When the entry names the test that kills it, run that
            # test alone: 0.25s against 17s for the suite. A red narrow run is a kill on the same
            # terms. A green one decides NOTHING and falls through to the full suite below, so a
            # survivor is never reported without a full run having gone green. If the named test
            # does not exist or did not run, the narrow result is discarded the same way.
            narrow = entry.get("test")
            resolved = False
            if narrow:
                n_ran, n_green, n_tail = run_tests(root, args.fuzz_seed, match_test=narrow)
                if n_ran and not n_green:
                    killed.append(entry)
                    print(f"[{eid}] killed (its named test {narrow} went red)")
                    resolved = True
                narrowed_attempted += 1
                if resolved:
                    narrowed_hit += 1
            if resolved:
                continue

            ran, green, tail = run_tests(root, args.fuzz_seed)
            if not ran:
                errors.append((entry, "the suite never ran under this mutation (the mutant does not compile)"))
                print(f"[{eid}] ERROR: the suite never ran under this mutation (the mutant does not "
                      f"compile). This is not a kill.")
                print(tail)
            elif green:
                survived.append(entry)
                print(f"[{eid}] SURVIVED: mutation left the suite green. Bound: {entry['function']} "
                      f"in {entry['file']} ({entry['bound']}).")
                print(tail)
            else:
                killed.append(entry)
                print(f"[{eid}] killed (suite went red, as required)")
        finally:
            if original:
                _atomic_write(target, original)
            # Removed only after the file on disk has been read back and confirmed identical to
            # the bytes the sentinel recorded. If the process dies between the restore above and
            # this clear, the sentinel survives and the next start redoes a restore that changes
            # nothing: the second of the two windows, failing the same safe direction.
            if pre_mutation is not None:
                clear_error = clear_sentinel(sentinel, target, pre_mutation)
                if clear_error:
                    print(f"[{eid}] WARNING: {clear_error}")
            post = git_dirty(repo_root)
            if post.strip():
                print(f"[{eid}] WARNING: tree not clean after restore:\n{post}")
            sys.stdout.flush()

    print()
    print(f"Summary: {len(killed)} killed, {len(survived)} survived, {len(errors)} errors, "
          f"{len(skipped)} skipped (redundant, proof recorded), {len(entries)} total.")
    if narrowed_attempted:
        print(f"Narrow-first: {narrowed_hit} of {narrowed_attempted} entries resolved by their "
              f"named test alone; the rest fell through to the full suite.")

    exit_code = 0
    if errors:
        print()
        print("ERRORS (job fails; not a kill for any of these):")
        for e, msg in errors:
            print(f"  [{e['id']}] {e['file']}: {e['function']}: {e['bound']}: {msg}")
        exit_code = 1
    if survived:
        print()
        print("SURVIVING MUTANTS (job fails):")
        for e in survived:
            print(f"  [{e['id']}] {e['file']}: {e['function']}: {e['bound']}")
        exit_code = 1

    final_dirty = git_dirty(repo_root)
    if final_dirty.strip():
        print("REFUSED to report success: the tree is not clean after the run.")
        print(final_dirty)
        return 2

    if exit_code == 0:
        print("Every catalogued mutation was killed. Tree confirmed clean.")
    return exit_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except _Terminated as exc:
        print(f"TERMINATED: {exc}")
        sys.exit(130)
    except _ToolMissing as exc:
        # Mid-loop: the entry's own finally already restored its file before this propagated.
        print(f"REFUSED: {exc}")
        sys.exit(2)
