//! Real fzf in a private PTY: keep disposable Rex frames through slow IPC,
//! restore ordinary tmux terminals, and publish hosted errors before acknowledgement.
#![cfg(unix)]

use std::process::Command;

const PROBE: &str = r###"
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import sys
import tempfile
import termios
import time

binary, fzf = sys.argv[1:]
sentinel = b'LAST_LOGIN_SENTINEL_BEHIND_PICKER'

snapshot = {
    'version': 1,
    'sessions': [
        {'session_id': 'session:target', 'label': 'target-project'},
        {'session_id': 'session:origin', 'label': 'origin-project'},
    ],
    'views': {
        'session:target': {'active_window_id': 'window:target', 'windows': [{
            'window_id': 'window:target', 'label': 'Target window',
            'focused_block_id': 'block:target',
            'layers': [{'kind': 'tiled', 'blocks': [
                {'block_id': 'block:target', 'label': 'target-shell'}]}],
        }]},
        'session:origin': {'active_window_id': 'window:origin', 'windows': [{
            'window_id': 'window:origin', 'label': 'Origin window',
            'focused_block_id': 'block:picker',
            'layers': [
                {'kind': 'tiled', 'blocks': [
                    {'block_id': 'block:origin', 'label': 'origin-shell'}]},
                {'kind': 'floating', 'blocks': [
                    {'block_id': 'block:picker', 'label': 'interdimux'}]},
            ],
        }]},
    },
    'errors': {},
}

def executable(path, text):
    path.write_text('#!' + sys.executable + '\n' + text)
    path.chmod(0o700)

def respond(fd, pending, chunk):
    pending += chunk
    # Match complete terminal requests, including one split across PTY reads.
    expression = rb'\x1b\[([0-?]*[ -/]*)([@-~])'
    end = 0
    for match in re.finditer(expression, pending):
        parameters, final = match.groups()
        answer = None
        if final == b'n' and parameters == b'6':
            answer = b'\x1b[1;1R'
        elif final == b'c' and parameters.startswith(b'>'):
            answer = b'\x1b[>84;0;0c'
        elif final == b'c' and parameters in (b'', b'0'):
            answer = b'\x1b[?1;2c'
        elif final == b'p' and re.fullmatch(rb'\?[0-9]+\$', parameters):
            answer = b'\x1b[' + parameters[:-1] + b';2$y'
        if answer:
            os.write(fd, answer)
        end = match.end()
    return pending[end:][-128:]

def probe(backend, action, hosted=False, fail=False):
    with tempfile.TemporaryDirectory(prefix='imux-terminal-') as temp:
        root = Path(temp)
        (root / 'snapshot.json').write_text(json.dumps(snapshot))
        log = root / 'calls.jsonl'
        result = root / 'result.json'
        executable(root / 'rex', '''import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
script = sys.stdin.read()
values = json.loads(args[args.index('--args') + 1])
operation = 'activate' if 'client.perform' in script else 'snapshot'
with open(os.environ['IMUX_TEST_CALLS'], 'a') as out:
    out.write(json.dumps({'operation': operation, 'args': values}) + '\\n')
if operation == 'snapshot':
    print(Path(os.environ['IMUX_TEST_SNAPSHOT']).read_text())
else:
    time.sleep(0.25)
    print('{}')
''')
        executable(root / 'tmux', '''import json, os, sys
args = sys.argv[1:]
with open(os.environ['IMUX_TEST_CALLS'], 'a') as out:
    out.write(json.dumps({'operation': 'tmux', 'args': args}) + '\\n')
u, r = '\\x1f', '\\x1e'
sections = [
    u.join(['$1','target-project','1000','1','attached','/tmp']),
    u.join(['$1','@1','target-project','0','Target window','1','shell','/tmp','1','0','000']),
    u.join(['$1','@1','%1','target-project','0','0','1','shell','/tmp','0','1','%1','shell','']),
    u.join(['target-project','0','0','host','host']), '',
]
if 'display-message' in args and 'list-windows' in args:
    print(('\\n'+r+'\\n').join(sections))
elif 'list-sessions' in args:
    print('$1')
elif 'list-clients' in args:
    print('/dev/imux-test')
elif 'switch-client' not in args:
    raise SystemExit('unexpected fake tmux invocation')
''')
        environment = dict(os.environ)
        for name in list(environment):
            if name.startswith(('INTERDIMUX_', 'REX_', 'FZF_')) or name in ('TMUX', 'TMUX_PANE', 'ESCDELAY'):
                del environment[name]
        environment.update({
            'TERM': 'xterm-256color',
            'PATH': str(root) + os.pathsep + os.environ.get('PATH', '/usr/bin:/bin'),
            'INTERDIMUX_FZF_BIN': str(root / 'missing-fzf') if fail else fzf,
            'INTERDIMUX_REX_BIN': str(root / 'rex'),
            'INTERDIMUX_ORDER': 'index',
            'INTERDIMUX_COLS': '120',
            'IMUX_TEST_CALLS': str(log),
            'IMUX_TEST_SNAPSHOT': str(root / 'snapshot.json'),
        })
        command = [binary, 'pick', '--backend', backend]
        if backend == 'rex':
            command += ['--client', 'client:origin', '--session', 'session:origin',
                        '--window', 'window:origin', '--block', 'block:origin',
                        '--picker-block', 'block:picker']
            if hosted:
                command += ['--snapshot', str(root / 'snapshot.json'), '--result', str(result)]
        else:
            command += ['--client', '/dev/imux-test', '--block', '%1', '--socket', str(root / 'tmux.sock')]

        child, master = pty.fork()
        if child == 0:
            os.write(1, sentinel + b'\r\n')
            os.execve(binary, command, environment)
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 28, 120, 0, 0))
        output = bytearray()
        after = bytearray()
        pending = b''
        sent = False
        acknowledged = False
        status = None
        start = time.monotonic()
        key_time = None
        startup_bytes = None
        startup_batches = None
        try:
            while time.monotonic() - start < 8:
                readable, _, _ = select.select([master], [], [], 0.02)
                if readable:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    output.extend(chunk)
                    if sent:
                        after.extend(chunk)
                    pending = respond(master, pending, chunk)
                if fail:
                    if b'Press Enter' in output and not acknowledged:
                        assert result.exists(), 'hosted error must be published before acknowledgement'
                        record = json.loads(result.read_text())
                        assert record['version'] == 1 and record['outcome'] == 'error', record
                        assert record.get('message'), record
                        assert os.waitpid(child, os.WNOHANG) == (0, 0), 'error terminal exited before acknowledgement'
                        assert not log.exists(), 'hosted error unexpectedly started the Rex CLI'
                        os.write(master, b'\r')
                        acknowledged = True
                elif not sent and b'target-project' in output:
                    assert b'\x1b[?1049h' in output, 'finder must enter the alternate screen'
                    startup_bytes = len(output)
                    startup_batches = bytes(output).count(b'\x1b[?2026h')
                    os.write(master, b'\x1b' if action == 'cancel' else b'\r')
                    key_time = time.monotonic()
                    sent = True
            found, status = os.waitpid(child, os.WNOHANG)
            while found == 0 and time.monotonic() - start < 8:
                time.sleep(0.005)
                found, status = os.waitpid(child, os.WNOHANG)
            if found == 0:
                raise AssertionError('picker did not exit; terminal tail: ' + repr(bytes(output[-1800:])))
        finally:
            if status is None:
                try:
                    os.killpg(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    os.waitpid(child, 0)
                except ChildProcessError:
                    pass
            os.close(master)
        if fail:
            assert acknowledged, repr(bytes(output))
            assert os.waitstatus_to_exitcode(status) == 1, status
            return {'backend': backend, 'hosted_error_acknowledged': True}
        assert sent, 'finder never painted candidate rows: ' + repr(bytes(output[-1800:]))
        assert os.waitstatus_to_exitcode(status) == 0, repr(bytes(output[-1800:]))
        assert sentinel not in after, 'old login text was rewritten after the selection key'
        if backend == 'rex':
            assert b'\x1b[?1049l' not in after, 'disposable Rex picker restored the old login screen'
            assert bytes(output).count(sentinel) == 1
            if hosted:
                assert not log.exists(), 'hosted picker unexpectedly started the Rex CLI'
                record = json.loads(result.read_text())
                assert record['version'] == 1, record
                assert record['outcome'] == ('cancel' if action == 'cancel' else 'select'), record
                if action == 'accept':
                    assert record['target']['session_id'] == 'session:target', record
            else:
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                assert [call['operation'] for call in calls] == ['snapshot', 'activate'], calls
                args = calls[1]['args']
                if action == 'cancel':
                    assert args['restore'] and args['session_id'] == 'session:origin', args
                else:
                    assert args['session_id'] == 'session:target' and not args.get('restore'), args
        else:
            assert b'\x1b[?1049l' in after, 'ordinary tmux terminal was left in the alternate screen'
        return {'backend': backend, 'action': action, 'hosted': hosted,
                'first_candidate_ms': round((key_time - start)*1000, 1),
                'startup_bytes': startup_bytes, 'startup_sync_batches': startup_batches,
                'key_to_exit_ms': round((time.monotonic() - key_time)*1000, 1)}

for backend, action, hosted in [
    ('rex', 'cancel', False), ('rex', 'accept', False),
    ('rex', 'cancel', True), ('rex', 'accept', True),
    ('tmux', 'cancel', False), ('tmux', 'accept', False),
]:
    print(json.dumps(probe(backend, action, hosted)), flush=True)
print(json.dumps(probe('rex', 'error', hosted=True, fail=True)), flush=True)
"###;

#[test]
fn real_fzf_preserves_disposable_frames_and_restores_inline_terminals() {
    let Ok(python) = Command::new("python3").arg("--version").output() else {
        eprintln!("Python 3 unavailable; skipping the PTY integration test");
        return;
    };
    if !python.status.success() {
        return;
    }
    let Ok(version) = Command::new("fzf").arg("--version").output() else {
        eprintln!("fzf unavailable; skipping the PTY integration test");
        return;
    };
    let version = String::from_utf8_lossy(&version.stdout);
    let numbers: Vec<u32> = version
        .split(|c: char| !c.is_ascii_digit())
        .filter(|part| !part.is_empty())
        .take(2)
        .filter_map(|part| part.parse().ok())
        .collect();
    if numbers.len() < 2 || (numbers[0], numbers[1]) < (0, 74) {
        eprintln!("fzf 0.74 or newer is required for modern terminal coverage; skipping");
        return;
    }
    let fzf = Command::new("python3")
        .args(["-c", "import shutil; print(shutil.which('fzf'))"])
        .output()
        .unwrap();
    let fzf = String::from_utf8(fzf.stdout).unwrap();
    let output = Command::new("python3")
        .args(["-c", PROBE, env!("CARGO_BIN_EXE_imux"), fzf.trim()])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "PTY probe failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
    eprintln!("{}", String::from_utf8_lossy(&output.stdout));
}
