//! The dashboard is a standalone key menu, before any target finder exists.
#![cfg(unix)]

use std::process::Command;

const PROBE: &str = r###"
import errno, fcntl, json, os, pty, re, select, signal, struct, sys, tempfile, termios, time
from pathlib import Path

binary, real_fzf = sys.argv[1:]
# Match the visible prefix; narrow identity columns shorten the full sentinel.
TREE = b'TREE_TARGET'

def respond(fd, pending, data):
    pending += data
    end = 0
    for match in re.finditer(rb'\x1b\[([0-?]*[ -/]*)([@-~])', pending):
        parameters, final = match.groups()
        answer = None
        if final == b'n' and parameters == b'6': answer = b'\x1b[1;1R'
        elif final == b'c' and parameters.startswith(b'>'): answer = b'\x1b[>84;0;0c'
        elif final == b'c' and parameters in (b'', b'0'): answer = b'\x1b[?1;2c'
        elif final == b'p' and re.fullmatch(rb'\?[0-9]+\$', parameters): answer = b'\x1b[' + parameters[:-1] + b';2$y'
        if answer: os.write(fd, answer)
        end = match.end()
    return pending[end:][-128:]

class Dashboard:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix='imux-dashboard-')
        self.root = Path(self.temp.name)
        self.result = self.root / 'result.json'
        self.output = bytearray()
        self.pending = b''
        self.status = None
        snapshot = {'version': 1, 'host_id': 'host:private',
            'sessions': [{'session_id': 'session:origin', 'label': 'TREE_SESSION_SENTINEL'}],
            'views': {'session:origin': {'active_window_id': 'window:origin', 'windows': [{
                'window_id': 'window:origin', 'label': 'TREE_WINDOW_SENTINEL', 'focused_block_id': 'block:origin',
                'layers': [{'kind': 'tiled', 'blocks': [
                    {'block_id': 'block:origin', 'label': 'TREE_TARGET_SENTINEL', 'host_id': 'host:private'},
                    {'block_id': 'block:other', 'label': 'other-terminal', 'host_id': 'host:private'},
                ]}],
            }]}}, 'metadata': {}, 'errors': {}}
        (self.root / 'snapshot.json').write_text(json.dumps(snapshot))
        wrapper = self.root / 'fzf'
        wrapper.write_text('#!' + sys.executable + '''
import json, os, sys
with open(os.environ['IMUX_DASHBOARD_LOG'], 'a') as output:
    output.write(json.dumps({'pid': os.getpid(), 'args': sys.argv[1:],
        'default_opts': os.environ.get('FZF_DEFAULT_OPTS'),
        'default_command': os.environ.get('FZF_DEFAULT_COMMAND')}) + '\\n')
os.execv(os.environ['IMUX_DASHBOARD_FZF'], [os.environ['IMUX_DASHBOARD_FZF'], *sys.argv[1:]])
''')
        wrapper.chmod(0o700)
        environment = dict(os.environ)
        for key in list(environment):
            if key.startswith(('INTERDIMUX_', 'REX_', 'FZF_')) or key in ('TMUX', 'TMUX_PANE', 'ESCDELAY'):
                environment.pop(key, None)
        environment.update(TERM='xterm-256color', HOME=str(self.root),
            XDG_DATA_HOME=str(self.root / 'data'), XDG_STATE_HOME=str(self.root / 'state'),
            XDG_CONFIG_HOME=str(self.root / 'config'), INTERDIMUX_FZF_BIN=str(wrapper),
            INTERDIMUX_REX_BIN=str(self.root / 'forbidden-rex'),
            INTERDIMUX_USE_ZOXIDE='off', INTERDIMUX_SHOW_FULL_COMMAND='off',
            INTERDIMUX_SHOW_GIT_BRANCH='off', INTERDIMUX_COLS='80',
            IMUX_DASHBOARD_LOG=str(self.root / 'fzf.jsonl'), IMUX_DASHBOARD_FZF=real_fzf,
            # An inherited zero/filter option must not skip the empty-input menu.
            FZF_DEFAULT_OPTS='--exit-0 --filter=POISON',
            FZF_DEFAULT_COMMAND='printf FORBIDDEN_WALKER')
        gate_read, gate_write = os.pipe()
        self.child, self.master = pty.fork()
        if self.child == 0:
            os.close(gate_write)
            os.read(gate_read, 1)
            os.close(gate_read)
            arguments = [binary, 'pick', '--mode', 'dashboard', '--backend', 'rex',
                '--client', 'client:app', '--session', 'session:origin', '--window', 'window:origin',
                '--block', 'block:origin', '--picker-block', 'block:picker',
                '--snapshot', str(self.root / 'snapshot.json'), '--result', str(self.result)]
            os.execve(binary, arguments, environment)
        os.close(gate_read)
        self.original = termios.tcgetattr(self.master)
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
        os.write(gate_write, b'x')
        os.close(gate_write)
        try:
            self.until(lambda: b'INTERDIMUX' in self.output, 'standalone dashboard')
            self.until(lambda: all(('[' + key + ']').encode() in self.output for key in 'sejnriwztaoh'),
                'all dashboard keys visible at 80x24')
            self.assert_dashboard()
        except BaseException:
            self.close()
            raise

    def launches(self):
        try: return [json.loads(line) for line in (self.root / 'fzf.jsonl').read_text().splitlines()]
        except FileNotFoundError: return []

    def pump(self, duration=.03):
        end = time.monotonic() + duration
        while time.monotonic() < end:
            if select.select([self.master], [], [], min(.005, max(0, end-time.monotonic())))[0]:
                try: data = os.read(self.master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO: return
                    raise
                if not data: return
                self.output.extend(data)
                self.pending = respond(self.master, self.pending, data)

    def until(self, condition, what, timeout=5):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if condition(): return
            self.pump(.01)
        raise AssertionError(what + ' timed out: ' + repr(bytes(self.output[-2500:])))

    def assert_dashboard(self):
        launches = self.launches()
        assert len(launches) == 1, launches
        assert '--no-input' in launches[0]['args'], launches
        assert '--disabled' in launches[0]['args'], launches
        assert launches[0]['default_opts'] is None, launches
        assert launches[0]['default_command'] is None, launches
        assert b'TREE_' not in self.output, 'target finder flashed before dashboard choice'
        assert not self.result.exists(), 'dashboard completed without a command'
        assert not (self.root / 'request.json').exists(), 'dashboard issued a backend request'

    def send(self, keys): os.write(self.master, keys)

    def finish(self, key=b'\x1b'):
        self.send(key)
        self.until(lambda: self.result.exists(), 'cancellation record')
        end = time.monotonic() + 3
        while time.monotonic() < end:
            done, status = os.waitpid(self.child, os.WNOHANG)
            if done:
                self.status = status
                break
            self.pump(.01)
        assert self.status is not None, 'dashboard/picker remained alive'
        assert os.waitstatus_to_exitcode(self.status) == 0, repr(bytes(self.output[-1500:]))
        assert json.loads(self.result.read_text()) == {'version': 1, 'outcome': 'cancel'}
        restored = termios.tcgetattr(self.master)
        assert restored == self.original, 'fzf failed to restore terminal attributes'
        assert restored[3] & termios.ICANON and restored[3] & termios.ECHO
        assert not (self.root / 'request.json').exists(), 'cancellation issued a backend request'

    def close(self):
        if self.status is None:
            try: os.killpg(self.child, signal.SIGKILL)
            except ProcessLookupError: pass
            try: os.waitpid(self.child, 0)
            except ChildProcessError: pass
        os.close(self.master)
        self.temp.cleanup()

def scenario(name, action):
    dashboard = Dashboard()
    try:
        action(dashboard)
        print(json.dumps({'scenario': name, 'fzf_launches': len(dashboard.launches()),
            'terminal_restored': True, 'backend_requests': 0}), flush=True)
    finally: dashboard.close()

def cancel(dashboard, key=b'\x1b'):
    dashboard.finish(key)
    assert len(dashboard.launches()) == 1
    assert b'TREE_' not in dashboard.output

def ignored(dashboard, keys):
    dashboard.send(keys)
    # Negative assertion: leave time for these queued input events to run.
    dashboard.pump(.12)
    dashboard.assert_dashboard()
    cancel(dashboard)

def route(dashboard, key, prompt):
    offset = len(dashboard.output)
    dashboard.send(key)
    dashboard.until(lambda: len(dashboard.launches()) == 2 and TREE in dashboard.output[offset:], 'one-key target finder')
    launches = dashboard.launches()
    assert '--no-input' not in launches[1]['args'], launches
    if prompt:
        assert any(arg.startswith('--prompt=' + prompt + ' · ') for arg in launches[1]['args']), launches
    assert not (dashboard.root / 'request.json').exists(), 'mode selection issued a backend request'
    dashboard.finish()
    assert len(dashboard.launches()) == 2, dashboard.launches()

scenario('escape closes only the dashboard', cancel)
scenario('q closes only the dashboard', lambda dashboard: cancel(dashboard, b'q'))
scenario('unknown key, Ctrl+z and Enter do not dispatch or stop', lambda dashboard: ignored(dashboard, b'x\x1a\r'))
scenario('Rex ignores unsupported detach', lambda dashboard: ignored(dashboard, b'd'))
scenario('s opens Switch immediately', lambda dashboard: route(dashboard, b's', None))
scenario('e opens Agents immediately', lambda dashboard: route(dashboard, b'e', 'Agents'))
scenario('r opens Rename immediately', lambda dashboard: route(dashboard, b'r', 'Rename'))
"###;

#[test]
fn standalone_dashboard_uses_legacy_hotkeys_without_a_finder_or_query() {
    let Ok(python) = Command::new("python3").arg("--version").output() else {
        eprintln!("Python 3 unavailable; skipping dashboard PTY coverage");
        return;
    };
    if !python.status.success() {
        return;
    }
    let Ok(version) = Command::new("fzf").arg("--version").output() else {
        eprintln!("fzf unavailable; skipping dashboard PTY coverage");
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
        eprintln!("fzf 0.74+ required; skipping dashboard PTY coverage");
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
        "Dashboard PTY probe failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    eprintln!("{}", String::from_utf8_lossy(&output.stdout));
}
