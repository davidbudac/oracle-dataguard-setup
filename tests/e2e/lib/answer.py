#!/usr/bin/env python3
"""
answer.py - run an interactive script under a pseudo-terminal and answer its
prompts by PATTERN, not by position.

    python3 answer.py --rules FILE|- --log FILE [--timeout S] [--cwd DIR]
                      [--env K=V ...] -- ./script.sh [args...]

Rules file: one rule per line, TAB-separated:

    <regex> <TAB> <answer> [<TAB> <flags>]

  * <regex> is searched (re.MULTILINE) in the ANSI-stripped output produced
    since the previous answer; it is anchored to the END of that text with
    an implicit ``\\s*\\Z``, so write the prompt's last line, optionally
    preceded by context lines (``Continue anyway\\?\\n.*proceed\\? \\[y/N\\]:``).
  * <answer> is sent followed by a newline. Empty = just Enter. ``\\n`` in
    the answer is a newline, ``\\t`` a tab; ``\\1``..``\\9`` expand to the
    regex's capture groups (read a menu number off the screen and answer it).
  * flags: ``secret`` (never written to the log/summary), ``once`` (the rule
    is consumed after its first match), ``fail`` (the prompt must NOT appear:
    it is answered, then the run is marked failed with exit 96).
  * ``#`` lines and blank lines are ignored. Rules are tried in order; the
    first match wins.

Behaviour:
  * Output is copied verbatim to stdout and to --log (so an ssh caller sees
    the script's output as a normal run would show it).
  * A prompt is "pending" when the script has been silent for IDLE seconds
    and its last line (no trailing newline) is non-empty. If a rule matches,
    the answer is sent. If no rule matches and the line looks like a prompt
    (ends with ':' or '?' plus optional spaces) for GRACE seconds, the run is
    aborted with exit 97 and ``UNANSWERED PROMPT: <line>`` on stderr - this
    is the "the script asked something the scenario did not foresee" finding.
  * Every answered prompt is appended to the log as ``[prompt] <text> =>
    <answer>`` (``***`` for secret rules) so the log doubles as the prompt
    sequence record for that run.
  * Exit status: the child's exit status, or 96 (forbidden prompt seen),
    97 (unanswered prompt), 98 (overall --timeout exceeded), 99 (usage).

Requires only the Python 3 standard library (3.6+).
"""
import argparse
import errno
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

ANSI_RE = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Z0-9]|\r')
PROMPTISH_RE = re.compile(r'[:?]\s*$')


class Rule(object):
    __slots__ = ('regex', 'answer', 'secret', 'once', 'fail', 'raw', 'hits')

    def __init__(self, raw, answer, flags):
        self.raw = raw
        # Anchor to the end of the unanswered text unless the author did.
        pattern = raw if raw.endswith(r'\Z') else raw + r'\s*\Z'
        self.regex = re.compile(pattern, re.MULTILINE)
        self.answer = answer.replace('\\n', '\n').replace('\\t', '\t')
        self.secret = 'secret' in flags
        self.once = 'once' in flags
        self.fail = 'fail' in flags
        self.hits = 0


def load_rules(path):
    data = sys.stdin.read() if path == '-' else open(path, encoding='utf-8').read()
    rules = []
    for lineno, line in enumerate(data.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        parts = line.split('\t')
        if len(parts) < 2:
            sys.stderr.write('answer.py: rule line %d has no TAB: %r\n' % (lineno, line))
            sys.exit(99)
        flags = set(f.strip() for f in parts[2].split(',')) if len(parts) > 2 else set()
        try:
            rules.append(Rule(parts[0], parts[1], flags))
        except re.error as exc:
            sys.stderr.write('answer.py: bad regex on line %d: %s\n' % (lineno, exc))
            sys.exit(99)
    return rules


def set_winsize(fd, rows=50, cols=200):
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    except OSError:
        pass


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument('--rules', required=True)
    ap.add_argument('--log', required=True)
    ap.add_argument('--timeout', type=float, default=7200.0)
    ap.add_argument('--idle', type=float, default=0.8)
    ap.add_argument('--grace', type=float, default=25.0)
    ap.add_argument('--cwd', default=None)
    ap.add_argument('--env', action='append', default=[])
    ap.add_argument('cmd', nargs=argparse.REMAINDER)
    args = ap.parse_args()
    cmd = args.cmd[1:] if args.cmd and args.cmd[0] == '--' else args.cmd
    if not cmd:
        sys.stderr.write('answer.py: no command given\n')
        sys.exit(99)

    rules = load_rules(args.rules)
    log = open(args.log, 'ab')
    log_state = {'at_line_start': True}

    def logwrite(chunk):
        log.write(chunk)
        log.flush()
        log_state['at_line_start'] = chunk.endswith(b'\n')

    def logline(text):
        # Records always start on their own line, even when the script's last
        # output (a prompt) had no trailing newline.
        prefix = b'' if log_state['at_line_start'] else b'\n'
        logwrite(prefix + (text + '\n').encode('utf-8', 'replace'))

    env = dict(os.environ)
    env.setdefault('TERM', 'xterm')
    env['COLUMNS'] = '200'
    env['LINES'] = '50'
    for kv in args.env:
        k, _, v = kv.partition('=')
        env[k] = v

    pid, master = pty.fork()
    if pid == 0:  # child
        if args.cwd:
            os.chdir(args.cwd)
        try:
            os.execvpe(cmd[0], cmd, env)
        except OSError as exc:
            sys.stderr.write('answer.py: cannot exec %s: %s\n' % (cmd[0], exc))
            os._exit(127)

    set_winsize(master)
    logline('[answer.py] started: %s' % ' '.join(cmd))

    start = time.time()
    last_output = start
    pending_since = None
    window = ''          # ANSI-stripped output since the last answer
    raw_tail = b''       # partial UTF-8 sequence carry-over
    outcome = None       # None = child's status; else forced exit code
    eof = False

    def send(answer):
        os.write(master, (answer + '\n').encode('utf-8'))

    while not eof:
        now = time.time()
        if now - start > args.timeout:
            logline('[answer.py] TIMEOUT after %.0fs' % args.timeout)
            sys.stderr.write('answer.py: TIMEOUT after %.0fs\n' % args.timeout)
            outcome = 98
            break
        try:
            ready, _, _ = select.select([master], [], [], 0.2)
        except InterruptedError:
            continue
        if ready:
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    eof = True
                    chunk = b''
                else:
                    raise
            if chunk:
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                logwrite(chunk)
                data = raw_tail + chunk
                try:
                    text = data.decode('utf-8')
                    raw_tail = b''
                except UnicodeDecodeError:
                    text = data[:-3].decode('utf-8', 'replace')
                    raw_tail = data[-3:]
                window += ANSI_RE.sub('', text)
                last_output = time.time()
                pending_since = None
                continue
            if eof:
                break
        # Silent for a while: is the last line a prompt?
        if time.time() - last_output < args.idle:
            continue
        last_line = window.rsplit('\n', 1)[-1]
        if not last_line.strip():
            continue
        matched = None
        m = None
        for rule in rules:
            if rule.once and rule.hits:
                continue
            m = rule.regex.search(window)
            if m:
                matched = rule
                break
        if matched is not None:
            matched.hits += 1
            answer = matched.answer
            if m.groups():
                # \1..\9 in the answer refer to the rule's capture groups, so
                # a rule can read a number off a printed menu and answer it.
                try:
                    answer = m.expand(answer)
                except (re.error, IndexError):
                    pass
            shown = '***' if matched.secret else answer.replace('\n', '\\n')
            logline('[prompt] %s => %s%s' % (last_line.strip(), shown,
                                              '  (FORBIDDEN)' if matched.fail else ''))
            if matched.fail and outcome is None:
                outcome = 96
                sys.stderr.write('answer.py: FORBIDDEN PROMPT: %s\n' % last_line.strip())
            send(answer)
            window = ''
            pending_since = None
            last_output = time.time()
            continue
        if PROMPTISH_RE.search(last_line):
            if pending_since is None:
                pending_since = time.time()
            elif time.time() - pending_since > args.grace:
                logline('[answer.py] UNANSWERED PROMPT: %s' % last_line.strip())
                sys.stderr.write('answer.py: UNANSWERED PROMPT: %s\n' % last_line.strip())
                outcome = 97
                break

    if outcome in (97, 98):
        try:
            os.kill(pid, signal.SIGTERM)
            time.sleep(1.0)
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    # Drain anything left so the log is complete.
    try:
        while True:
            ready, _, _ = select.select([master], [], [], 0.3)
            if not ready:
                break
            chunk = os.read(master, 65536)
            if not chunk:
                break
            sys.stdout.buffer.write(chunk)
            logwrite(chunk)
    except OSError:
        pass
    sys.stdout.buffer.flush()
    _, status = os.waitpid(pid, 0)
    child_rc = os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)
    unused = [r.raw for r in rules if r.hits == 0 and r.once]
    logline('[answer.py] child exit %d; prompts answered: %d; unused once-rules: %s'
            % (child_rc, sum(r.hits for r in rules), ', '.join(unused) or 'none'))
    log.close()
    sys.exit(outcome if outcome is not None else child_rc)


if __name__ == '__main__':
    main()
