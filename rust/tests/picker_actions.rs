//! Real fzf remains alive while the shared controller handles native actions.
//! A private file mailbox stands in for Rex; no user terminal or Rex app is used.
#![cfg(unix)]

use std::process::Command;

const PROBE: &str = r###"
import copy, errno, fcntl, http.client, json, os, pty, re, select, signal, socket, struct, sys, tempfile, termios, threading, time
from pathlib import Path

binary, real_fzf = sys.argv[1:]

def write_json(path, value):
    temporary = path.with_suffix(path.suffix + '.test-tmp')
    temporary.write_text(json.dumps(value))
    temporary.replace(path)

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

class Picker:
    def __init__(self, raw=True, mode=None, live=False, theme=None, direct=False, snapshot_setup=None, agent_states=None):
        self.temp = tempfile.TemporaryDirectory(prefix='imux-actions-')
        self.root = Path(self.temp.name)
        self.snapshot_path = self.root / 'snapshot.json'
        self.result_path = self.root / 'result.json'
        self.requests = []
        self.faults = []
        self.stop = threading.Event()
        self.output = bytearray()
        self.pending = b''
        self.status = None
        self.snapshot = {
            'version': 1,
            'sessions': [
                {'session_id': 'session:target', 'label': 'target-project'},
                {'session_id': 'session:origin', 'label': 'origin-project'},
            ],
            'views': {
                'session:target': {'active_window_id': 'window:target', 'windows': [{
                    'window_id': 'window:target', 'label': 'Target window', 'focused_block_id': 'block:selected',
                    'layers': [{'kind': 'tiled', 'blocks': [
                        {'block_id': 'block:selected', 'label': 'selected-pane'},
                        {'block_id': 'block:other', 'label': 'other-pane'},
                    ]}],
                }]},
                'session:origin': {'active_window_id': 'window:origin', 'windows': [{
                    'window_id': 'window:origin', 'label': 'Origin window', 'focused_block_id': 'block:origin',
                    'layers': [{'kind': 'tiled', 'blocks': [{'block_id': 'block:origin', 'label': 'origin-pane'}]}],
                }]},
            },
            'metadata': {
                'block:selected': {'foreground': {'name': 'sleep', 'cwd': str(self.root), 'pid': 0}},
                'block:other': {'foreground': {'name': 'shell', 'cwd': str(self.root), 'pid': 0}},
            },
            'errors': {},
        }
        if snapshot_setup is not None: snapshot_setup(self.snapshot)
        write_json(self.snapshot_path, self.snapshot)
        if live: write_json(self.root / 'live.json', {'version': 1})
        probe = self.root / 'dashboard-result.py'
        probe.write_text('import json, os\nfrom pathlib import Path\np=Path(os.environ["IMUX_DASHBOARD_STATE"])\nt=p.with_suffix(".tmp")\nt.write_text(json.dumps({"query":os.environ.get("FZF_QUERY"),"item":os.environ.get("FZF_CURRENT_ITEM"),"matches":os.environ.get("FZF_MATCH_COUNT"),"raw":os.environ.get("FZF_RAW")}))\nt.replace(p)\n')
        wrapper = self.root / 'fzf'
        wrapper.write_text('#!' + sys.executable + '''
import json, os, shlex, sys
with open(os.environ['IMUX_FZF_LOG'], 'a') as out:
    out.write(json.dumps({'pid': os.getpid(), 'args': sys.argv[1:], 'query': os.environ.get('FZF_QUERY'), 'current_item': os.environ.get('FZF_CURRENT_ITEM'), 'theme': os.environ.get('INTERDIMUX_THEME')}) + '\\n')
arguments = sys.argv[1:]
command = shlex.quote(sys.executable) + ' ' + shlex.quote(os.environ['IMUX_DASHBOARD_PROBE'])
if any(argument.startswith('--prompt=Dashboard ') for argument in arguments):
    arguments += ['--bind=result:execute-silent(' + command + ')']
elif '--style=minimal' in arguments and os.environ.get('IMUX_INITIAL_MODE') == 'rename':
    arguments += ['--bind=ctrl-y:wait+execute-silent(' + command + ')']
if '--style=minimal' in arguments and os.environ.get('IMUX_LIVE_STARTUP'):
    from pathlib import Path
    path = Path(os.environ['IMUX_LIVE_STARTUP'])
    snapshot = json.loads(path.read_text())
    snapshot['views']['session:target']['windows'][0]['layers'][0]['blocks'][0]['label'] = 'selected-before-start'
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(snapshot))
    temporary.replace(path)
os.execv(os.environ['IMUX_REAL_FZF'], [os.environ['IMUX_REAL_FZF'], *arguments])
''')
        wrapper.chmod(0o700)
        rex = self.root / 'rex'
        rex.write_text('#!' + sys.executable + '''
import os
open(os.environ['IMUX_FORBIDDEN_CLI'], 'a').write('unexpected Rex CLI\\n')
raise SystemExit(91)
''')
        rex.chmod(0o700)
        environment = dict(os.environ)
        for key in list(environment):
            if key.startswith(('INTERDIMUX_', 'REX_', 'FZF_')) or key in ('TMUX', 'TMUX_PANE', 'ESCDELAY', 'NO_COLOR'):
                environment.pop(key, None)
        environment.update({
            'TERM': 'xterm-256color', 'HOME': str(self.root), 'XDG_DATA_HOME': str(self.root / 'data'),
            'XDG_STATE_HOME': str(self.root / 'state'),
            'PATH': str(self.root) + os.pathsep + os.environ.get('PATH', '/usr/bin:/bin'),
            'INTERDIMUX_FZF_BIN': str(wrapper), 'INTERDIMUX_REX_BIN': str(rex),
            'INTERDIMUX_ORDER': 'index', 'INTERDIMUX_COLS': '120', 'INTERDIMUX_USE_ZOXIDE': 'off',
            'INTERDIMUX_RAW': 'on' if raw else 'off',
            'INTERDIMUX_PROJECT_DIRS': str(self.root / 'projects'),
            'IMUX_FZF_LOG': str(self.root / 'fzf.jsonl'), 'IMUX_REAL_FZF': real_fzf,
            'IMUX_FORBIDDEN_CLI': str(self.root / 'forbidden-cli'),
            'IMUX_DASHBOARD_PROBE': str(probe), 'IMUX_DASHBOARD_STATE': str(self.root / 'dashboard-state.json'),
            'IMUX_INITIAL_MODE': mode or '',
            'FZF_API_KEY': 'inherited-unrelated-key',
            'IMUX_LIVE_STARTUP': str(self.snapshot_path) if live == 'startup' else '',
        })
        if theme is not None: environment['INTERDIMUX_THEME'] = theme
        self.environment = environment
        (self.root / 'projects' / 'example').mkdir(parents=True)
        command = [binary, mode if direct else 'pick', '--backend', 'rex', '--client', 'client:origin', '--session', 'session:origin',
                   '--window', 'window:origin', '--block', 'block:origin', '--picker-block', 'block:picker',
                   '--snapshot', str(self.snapshot_path), '--result', str(self.result_path)]
        if mode and not direct: command += ['--mode', mode]
        if agent_states is not None: command += ['--agent-states', agent_states]
        self.thread = threading.Thread(target=self.coordinate, daemon=True)
        # Fork before starting a Python thread. A child cannot safely perform
        # Python/exec setup with locks inherited from a running coordinator.
        self.child, self.master = pty.fork()
        if self.child == 0:
            os.execve(binary, command, environment)
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack('HHHH', 28, 120, 0, 0))
        self.thread.start()
        try:
            if mode == 'dashboard':
                self.until(lambda: any('--no-input' in launch['args'] for launch in self.launches()), 'standalone Dashboard')
                self.until(lambda: b'INTERDIMUX' in self.output and b'NAVIGATE' in self.output, 'standalone Dashboard frame')
            elif mode in ('jobs','dirs','doctor'):
                prompt = {'jobs':'Jobs','dirs':'Directories','doctor':'Health'}[mode]
                self.until(lambda: any(any(arg.startswith('--prompt='+prompt+' ') for arg in launch['args']) for launch in self.launches()), 'startup '+prompt)
                self.until(lambda: (prompt+' ❯').encode() in self.output, 'startup '+prompt+' frame')
            else:
                self.until(lambda: (b'selected-before-start' if live == 'startup' else b'selected-pane') in self.output, 'initial finder')
        except BaseException:
            self.close()
            raise
        self.main_pid = self.launches()[0]['pid']

    def coordinate(self):
        previous = None
        try:
            while not self.stop.wait(.001):
                try: request = json.loads((self.root / 'request.json').read_text())
                except (FileNotFoundError, json.JSONDecodeError): continue
                if request['id'] == previous: continue
                previous = request['id']
                self.requests.append(copy.deepcopy(request))
                operation, target, args = request['operation'], request.get('target') or {}, request.get('args') or {}
                data = {}
                if operation == 'snapshot': write_json(self.snapshot_path, self.snapshot)
                elif operation == 'rename':
                    for view in self.snapshot['views'].values():
                        for window in view['windows']:
                            for layer in window['layers']:
                                for block in layer['blocks']:
                                    if block['block_id'] == target.get('block_id'): block['label'] = args['name']
                elif operation == 'close':
                    for view in self.snapshot['views'].values():
                        for window in view['windows']:
                            for layer in window['layers']:
                                layer['blocks'] = [b for b in layer['blocks'] if b['block_id'] != target.get('block_id')]
                elif operation == 'preview': data = {'text': '\x1b[32mCAPTURE_SENTINEL\x1b[0m\nlatest output\n'}
                elif operation == 'create': data = {'target': {'session_id': 'session:created', 'window_id': 'window:created', 'block_id': 'block:created'}}
                elif operation != 'send': raise AssertionError('unexpected operation: ' + operation)
                if operation != 'preview': write_json(self.snapshot_path, self.snapshot)
                write_json(self.root / 'response.json', {'version': 1, 'id': request['id'], 'ok': True, 'data': data})
        except BaseException as error:
            self.faults.append(repr(error))

    def launches(self):
        try: return [json.loads(line) for line in (self.root / 'fzf.jsonl').read_text().splitlines()]
        except FileNotFoundError: return []

    def top_launches(self): return [entry for entry in self.launches() if '--style=minimal' in entry['args']]
    def calls(self, operation): return [request for request in self.requests if request['operation'] == operation]
    def send(self, keys): os.write(self.master, keys)

    def pump(self, duration=.08):
        until = time.monotonic() + duration
        while time.monotonic() < until:
            ready, _, _ = select.select([self.master], [], [], min(.01, max(0, until-time.monotonic())))
            if ready:
                try: chunk = os.read(self.master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO: return
                    raise
                if not chunk: return
                self.output.extend(chunk)
                self.pending = respond(self.master, self.pending, chunk)
        assert not self.faults, self.faults

    def until(self, condition, description, timeout=6):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if condition(): return
            self.pump(.02)
        raise AssertionError(description + ' timed out; requests=' + repr(self.requests) + '; terminal=' + repr(bytes(self.output[-2500:])))

    def query(self, query='selected-pane'):
        self.send(b'\x1b[F\x15' + query.encode())
        self.pump(.15)

    def dialog(self, key, prompt, initial=None):
        before = len(self.launches())
        self.send(key)
        self.until(lambda: len(self.launches()) > before, prompt + ' launch')
        launch = self.launches()[-1]
        assert any(arg.startswith('--prompt=' + prompt) for arg in launch['args']), launch
        if initial is not None: assert '--query=' + initial in launch['args'], launch
        self.pump(.10)
        return launch

    def stable(self):
        assert len(self.top_launches()) == 1, self.launches()
        assert self.top_launches()[0]['pid'] == self.main_pid
        os.kill(self.main_pid, 0)
        assert not (self.root / 'forbidden-cli').exists(), 'hosted navigator started Rex CLI'

    def finish(self, cancel=True):
        if cancel: self.send(b'\x1b')
        self.until(lambda: self.result_path.exists(), 'completion record')
        self.pump(.10)
        until = time.monotonic() + 3
        while time.monotonic() < until:
            found, status = os.waitpid(self.child, os.WNOHANG)
            if found:
                self.status = status
                assert os.waitstatus_to_exitcode(status) == 0, repr(bytes(self.output[-2000:]))
                break
            self.pump(.02)
        assert self.status is not None, 'imux remained alive after completion'
        assert not (self.root / 'forbidden-cli').exists(), 'hosted navigator started Rex CLI'
        return json.loads(self.result_path.read_text())

    def close(self):
        if self.status is None:
            try: os.killpg(self.child, signal.SIGKILL)
            except ProcessLookupError: pass
        # macOS can keep a killed terminal process in its exit path until the
        # PTY master closes. Release it before waitpid so a failed assertion
        # reports its original error instead of hanging during cleanup.
        os.close(self.master)
        if self.status is None:
            try: os.waitpid(self.child, 0)
            except ChildProcessError: pass
        self.stop.set()
        self.thread.join(timeout=1)
        self.temp.cleanup()

def finder_state(p):
    # GET is read-only, but fzf may be painting while it services the request.
    # Keep draining the PTY so terminal backpressure cannot block the reply.
    outcome = []
    def read():
        try:
            with socket.socket(socket.AF_UNIX) as stream:
                stream.settimeout(2)
                stream.connect(str(p.root / 'ui' / 'f.sock'))
                stream.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
                response = http.client.HTTPResponse(stream)
                response.begin()
                outcome.append((True, json.loads(response.read())))
        except BaseException as error:
            outcome.append((False, error))
    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    while reader.is_alive(): p.pump(.01)
    reader.join()
    success, value = outcome[0]
    if not success: raise value
    return value

def scenario(name, run, raw=True, mode=None, live=False):
    picker = Picker(raw=raw, mode=mode, live=live)
    try:
        run(picker)
        print(json.dumps({'scenario': name, 'backend_operations': [r['operation'] for r in picker.requests], 'fzf_spawns': len(picker.launches())}), flush=True)
    finally: picker.close()

def refresh_scope(p):
    p.query()
    assert not p.requests, 'typing ran a backend callback'
    p.send(b'\x12')
    p.until(lambda: len(p.calls('snapshot')) == 1, 'refresh')
    p.pump(.15)
    launch = p.dialog(b'\x05', 'Rename', 'selected-pane')
    assert launch['query'] == 'selected-pane', launch
    assert re.search(r'\timux:[0-9]+$', launch['current_item'] or ''), 'FZF_CURRENT_ITEM lost the original hidden token: ' + repr(launch)
    p.send(b'\x1b'); p.pump(.15)
    before = len(p.requests)
    for label in [b'name', b'path', b'cmd', b'all', b'name+cmd'] * 4:
        offset = len(p.output)
        p.send(b'\x1d')
        p.until(lambda: label + ' ❯ '.encode() in p.output[offset:], 'scope ' + repr(label))
        p.pump(.10)
    assert len(p.requests) == before, 'scope cycling queried the backend'
    p.stable()
    assert p.finish()['outcome'] == 'cancel'

def rename(p):
    p.query()
    p.dialog(b'\x05', 'Rename', 'selected-pane')
    p.send(b'\x1b[F\x15renamed-pane\r')
    p.until(lambda: len(p.calls('rename')) == 1, 'rename')
    p.until(lambda: b'renamed-pane' in p.output, 'updated label')
    p.pump(.10)
    launch = p.dialog(b'\x0f', 'Directories')
    assert launch['query'] == 'selected-pane', 'rename lost the main query: ' + repr(launch)
    p.send(b'\x1b'); p.pump(.15)
    p.query('renamed-pane')
    p.dialog(b'\x05', 'Rename', 'renamed-pane')
    p.send(b'\x1b'); p.pump(.15)
    assert p.calls('rename')[0]['target']['block_id'] == 'block:selected'
    p.stable(); p.finish()

def close_confirm(p):
    p.query()
    p.dialog(b'\x18', 'Confirm')
    p.send(b'\x1b'); p.pump(.20)
    assert not p.calls('close'), 'cancelled confirmation closed a target'
    p.dialog(b'\x18', 'Confirm')
    p.send(b'\x0e\r')
    p.until(lambda: len(p.calls('close')) == 1, 'confirmed close')
    assert p.calls('close')[0]['target']['block_id'] == 'block:selected'
    p.pump(.15)
    p.stable(); p.finish()

def dimmed_guard(p):
    p.query()
    before = len(p.launches())
    p.send(b'\x1b[A'); p.pump(.05)
    p.send(b'\x05'); p.pump(.30)
    assert len(p.launches()) == before, 'dimmed target opened an action dialog'
    assert not p.requests, 'dimmed target reached native backend'
    p.send(b'\x0e'); p.pump(.08)
    p.dialog(b'\x05', 'Rename', 'selected-pane')
    p.send(b'\x1b'); p.pump(.12)
    p.stable(); p.finish()

def preview(p):
    p.query()
    p.send(b'\x1f')
    p.until(lambda: len(p.calls('preview')) >= 1, 'preview capture')
    p.until(lambda: b'CAPTURE_SENTINEL' in p.output, 'preview output')
    request = p.calls('preview')[0]
    assert request['target']['block_id'] == 'block:selected', request
    assert 0 < request['args']['lines'] <= 28, request
    p.send(b'\x1f'); p.pump(.10)
    before = len(p.requests)
    p.query('selected-pan')
    assert len(p.requests) == before, 'hidden preview or typing queried backend'
    p.stable(); p.finish()

def send_literal(p):
    p.query()
    p.dialog(b'\x14', 'Send')
    marker = p.root / 'must-not-exist'
    text = "$(touch " + str(marker) + "); printf '$HOME'"
    p.send(text.encode() + b'\r')
    p.until(lambda: len(p.calls('send')) == 1, 'literal send')
    request = p.calls('send')[0]
    assert request['target']['block_id'] == 'block:selected'
    assert request['args'] == {'text': text, 'enter': True}, request
    assert not marker.exists(), 'query/command text was evaluated by the picker'
    p.pump(.15)
    p.stable(); p.finish()

def forced_create(p):
    p.query('made-session')
    p.send(b'\x1b\r')
    p.until(lambda: len(p.calls('create')) == 1, 'Alt+Enter create')
    request = p.calls('create')[0]
    assert request['args']['name'] == 'made-session', request
    assert request['args']['cwd'] == str(p.root), request
    record = p.finish(cancel=False)
    assert record['outcome'] == 'select' and record['target']['session_id'] == 'session:created', record
    assert len(p.top_launches()) == 1, 'creation restarted the main fzf'

def plain_filter_create(p):
    p.query('plain-created-session')
    p.send(b'\r')
    p.until(lambda: len(p.calls('create')) == 1, 'plain filtering zero-match Enter create')
    request = p.calls('create')[0]
    assert request['args']['name'] == 'plain-created-session', request
    record = p.finish(cancel=False)
    assert record['outcome'] == 'select' and record['target']['session_id'] == 'session:created', record
    assert len(p.top_launches()) == 1, 'plain-filter creation restarted the main fzf'

def plain_filter_global_actions(p):
    p.query('no-existing-target-matches')
    p.send(b'\x12')
    p.until(lambda: len(p.calls('snapshot')) == 1, 'plain-filter zero-match refresh')
    p.pump(.10)
    launch = p.dialog(b'\x0f', 'Directories')
    assert launch['query'] == 'no-existing-target-matches', launch
    p.send(b'\x1b'); p.pump(.15)
    launch = p.dialog(b'\x07', 'Actions')
    assert launch['query'] == 'no-existing-target-matches', launch
    p.send(b'\x1b'); p.pump(.15)
    assert [request['operation'] for request in p.requests] == ['snapshot'], p.requests
    p.stable(); p.finish()

def empty_agents_mode(p):
    assert '--query=^! | ^? | ^× | ^✓ | ^·' in p.top_launches()[0]['args'], p.top_launches()
    p.pump(.15)
    assert not p.result_path.exists(), 'empty attention filter must stay open, not auto-exit'
    p.query('selected-pane')
    p.send(b'\r')
    record = p.finish(cancel=False)
    assert record['outcome'] == 'select' and record['target']['block_id'] == 'block:selected', record
    assert not p.calls('create'), 'agent state filters must never become new sessions'


def assert_raw(p):
    attributes = termios.tcgetattr(p.master)
    assert not attributes[3] & termios.ICANON, 'nested modal inherited a cooked canonical TTY'
    assert not attributes[3] & termios.ECHO, 'nested modal left terminal echo enabled'

def startup_escape(p):
    p.pump(.10)
    assert_raw(p)
    result = p.finish()
    assert result['outcome'] == 'cancel', result
    assert not p.requests, 'startup cancellation must not mutate the backend'

def dashboard_agents_key(p):
    assert_raw(p)
    p.send(b'e')
    p.until(lambda: b'Agents \xc2\xb7' in p.output, 'Dashboard e did not choose Agents mode')
    assert_raw(p)
    result = p.finish()
    assert result['outcome'] == 'cancel', result

def dashboard_rename_key(p):
    assert_raw(p)
    p.send(b'r')
    p.until(lambda: b'Rename \xc2\xb7' in p.output, 'Dashboard r did not choose Rename mode')
    assert_raw(p)
    result = p.finish()
    assert result['outcome'] == 'cancel', result
    assert not p.calls('rename'), 'choosing Rename mode must not rename a target'

def enter_mode_modal_escape(p):
    p.query('selected-pane')
    def state():
        try: return json.loads((p.root / 'dashboard-state.json').read_text())
        except (FileNotFoundError, json.JSONDecodeError): return {}
    # A test-only wait/probe key observes fzf's settled search without changing
    # production bindings. Explicit match navigation covers a still-dim cursor.
    p.send(b'\x19')
    p.until(lambda: state().get('query') == 'selected-pane' and state().get('matches') == '1', 'Rename target query did not settle')
    if 'selected-pane' not in state().get('item', '') or state().get('raw') != '1':
        p.send(b'\x0e\x19')
        p.until(lambda: 'selected-pane' in state().get('item', '') and state().get('raw') == '1', 'Rename target was not focused')
    p.dialog(b'\r', 'Rename', initial='selected-pane')
    assert_raw(p)
    before = len(p.output)
    p.send(b'\x1b')
    p.until(lambda: b'Rename \xc2\xb7' in p.output[before:], 'Escape did not return from Rename modal')
    assert not p.calls('rename'), 'Escape from Enter-mode modal must preserve the pane'
    assert_raw(p)
    p.finish()

def live_updates(p):
    def probe():
        # Read-only observation must not execute another action: execute-silent
        # itself can cancel an in-flight transform, perturbing the behavior.
        value = finder_state(p)
        return {'query': value['query'], 'item': (value.get('current') or {}).get('text', ''), 'matches': str(value['matchCount'])}
    p.query('selected')
    p.send(b'\x0e')
    before = probe()
    assert 'selected-pane' in before['item'], before
    token = before['item'].split('\t')[-1]
    blocks = p.snapshot['views']['session:target']['windows'][0]['layers'][0]['blocks']
    blocks.insert(0, {'block_id': 'block:new', 'label': 'selected-new'})
    blocks[1]['label'] = 'selected-renamed'
    write_json(p.snapshot_path, p.snapshot)
    p.until(lambda: b'selected-renamed' in re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', bytes(p.output)), 'live rename/create rendering')
    after = probe()
    assert after['query'] == 'selected', after
    assert 'selected-renamed' in after['item'] and after['item'].split('\t')[-1] == token, (before, after)
    assert after['matches'] == '2', after
    # Invalid/partial snapshots do not discard the last good rows or selection.
    p.snapshot_path.write_text('{invalid')
    p.pump(.3)
    assert probe()['item'] == after['item']
    write_json(p.snapshot_path, p.snapshot)
    p.pump(.3)
    p.stable()
    assert not p.calls('snapshot'), p.requests
    calls = len(p.requests)
    p.pump(.6)
    assert len(p.requests) == calls, 'idle live picker performed backend requests'
    # Incoming updates while a modal owns the terminal must coalesce and must
    # not capture the modal's query or run its pending destructive action.
    p.dialog(b'\x05', 'Rename', initial='selected-renamed')
    p.send(b'\x15do-not-submit')
    blocks.insert(0, {'block_id': 'block:during-dialog', 'label': 'dialog-addition'})
    for index in range(15):
        blocks[-1]['label'] = 'background-update-' + str(index)
        write_json(p.snapshot_path, p.snapshot)
        p.pump(.08)
    p.send(b'\x1b')
    p.pump(.4)
    assert not p.calls('rename'), p.requests
    after_dialog = probe()
    assert after_dialog['query'] == 'selected' and after_dialog['item'].split('\t')[-1] == token, after_dialog
    p.stable()
    # Removing a focused pane must not reuse its token for a different target.
    blocks[:] = [b for b in blocks if b['block_id'] != 'block:selected']
    write_json(p.snapshot_path, p.snapshot)
    p.until(lambda: probe()['matches'] == '1', 'focused removal live update')
    after = probe()
    assert after['query'] == 'selected' and after['matches'] == '1', after
    assert after['item'].split('\t')[-1] != token, after
    p.send(b'\x0e\r')
    result = p.finish(cancel=False)
    assert result['target']['block_id'] == 'block:new', result

def live_empty_results(p):
    def screen():
        decoder = Cursor(28, 120)
        decoder.feed(bytes(p.output), 0)
        return decoder.visible()
    def header(): return screen()[1]
    def match_count(): return finder_state(p)['matchCount']
    guidance = 'Enter creates a session from the query'
    p.query('live-match')
    p.until(lambda: guidance in header(), 'zero-match guidance')
    blocks = p.snapshot['views']['session:target']['windows'][0]['layers'][0]['blocks']
    blocks[0]['label'] = 'live-match'
    write_json(p.snapshot_path, p.snapshot)
    p.until(lambda: match_count() == 1, 'newly matching live row')
    p.until(lambda: guidance not in header(), 'stale creation guidance must clear after a live match appears')
    p.query('never-here')
    p.until(lambda: guidance in header(), 'empty guidance after changing query')
    blocks[0]['label'] = 'changed-while-unmatched'
    write_json(p.snapshot_path, p.snapshot)
    p.until(lambda: any('changed-while-unmatched' in row for row in screen()[2:-1]), 'live update while no rows match')
    p.pump(.2)
    assert guidance in header(), 'zero-to-zero refresh lost creation guidance: '+header()
    p.finish()

def live_typing(p):
    def state(): return finder_state(p)
    blocks = p.snapshot['views']['session:target']['windows'][0]['layers'][0]['blocks']
    for round_number in range(2):
        query = 'typing-round-' + str(round_number)
        p.query('')
        blocks[0]['label'] = query
        for index, character in enumerate(query):
            # Each publication changes actual rows, while separate key events
            # arrive more frequently than the 150ms idle threshold. A reload
            # must wait rather than blocking fzf and losing part of the query.
            blocks[1]['label'] = 'background-typing-' + str(round_number) + '-' + str(index)
            write_json(p.snapshot_path, p.snapshot)
            p.send(character.encode())
            p.pump(.09)
        p.pump(.1)
        assert state()['query'] == query, 'live reload lost typed characters: ' + repr(state())
        blocks[0]['label'] = query + '-latest'
        write_json(p.snapshot_path, p.snapshot)
        p.until(lambda: any(query + '-latest' in row['text'] for row in state()['matches']),
                'latest publication must render after typing stops')
        def latest_visible():
            screen = Cursor(28, 120)
            screen.feed(bytes(p.output), 0)
            return any(query + '-latest' in row for row in screen.visible()[1:-1])
        p.until(latest_visible, 'latest matching row must be visible in the terminal')
        assert state()['query'] == query, 'deferred reload changed the completed query'
        p.stable()
    assert not p.calls('snapshot'), p.requests
    p.finish()

scenario('live-typing-raw', live_typing, live=True)
scenario('live-typing-filtered', live_typing, live=True, raw=False)
scenario('live-empty-result-guidance', live_empty_results, live=True)
scenario('live-startup-publication-race', lambda p: p.finish(), live='startup')
scenario('live-query-selection-raw', live_updates, live=True)
scenario('live-query-selection-filtered', live_updates, live=True, raw=False)

for attempt in range(3):
    scenario('dashboard-startup-escape-'+str(attempt), startup_escape, mode='dashboard')
scenario('dashboard-agent-key', dashboard_agents_key, mode='dashboard')
scenario('dashboard-rename-key', dashboard_rename_key, mode='dashboard')
scenario('enter-mode-rename-escape', enter_mode_modal_escape, mode='rename')
scenario('jobs-startup-escape', startup_escape, mode='jobs')
scenario('directories-startup-escape', startup_escape, mode='dirs')

scenario('empty-agents-mode', empty_agents_mode, mode='agents')

for name, run in [('refresh-scope', refresh_scope), ('rename-query', rename), ('close-confirmation', close_confirm),
                  ('dimmed-guard', dimmed_guard), ('preview', preview), ('send-literal', send_literal), ('forced-create', forced_create)]:
    scenario(name, run)
for attempt in range(4):
    scenario('forced-create-stress-' + str(attempt + 1), forced_create)
scenario('plain-filter-zero-enter', plain_filter_create, raw=False)
scenario('plain-filter-zero-global-actions', plain_filter_global_actions, raw=False)
"###;

const AGENTS_PROBE: &str = r###"
def attention_snapshot(snapshot):
    statuses = [('permission', 'blocked', 'permission'), ('question', 'blocked', 'question'),
                ('done', 'done', ''), ('working', 'working', ''),
                ('idle', 'idle', ''), ('error', 'error', '')]
    target = snapshot['views']['session:target']['windows'][0]
    target['layers'][0]['blocks'] = []
    for index, (label, state, detail) in enumerate(statuses):
        split_id = 'block:selected' if index == 0 else 'block:split-' + label
        split_label = 'selected-pane' if index == 0 else 'split-' + label
        target['layers'][0]['blocks'].append({'block_id': split_id, 'label': split_label})
        single_id, window_id = 'block:single-' + label, 'window:single-' + label
        snapshot['views']['session:target']['windows'].append({
            'window_id': window_id, 'label': 'single-' + label, 'focused_block_id': single_id,
            'layers': [{'kind': 'tiled', 'blocks': [{'block_id': single_id, 'label': 'single-' + label}]}],
        })
        for offset, block_id in enumerate([split_id, single_id]):
            # Rex hooks can publish a current, owned status from the shell
            # hosting an agent. Verify both row shapes survive shell guards.
            process = 'zsh' if label == 'permission' and offset == 1 else 'bash' if label == 'question' and offset == 0 else 'codex'
            owner = {'name': process, 'pid': 1000 + index * 2 + offset}
            snapshot['metadata'][block_id] = {
                'foreground': dict(owner),
                'program_status': {'records': [{'owner': owner, 'state': state, 'kind': detail,
                                                 'updated_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() - 10))}]},
            }

for wanted, raw in [('approve,input', True), ('approve,input', False), (None, True), (None, False)]:
    p = Picker(raw=raw, mode='agents', live=True, snapshot_setup=attention_snapshot,
               agent_states=wanted)
    try:
        expected = [('selected-pane', '!'), ('split-question', '?'),
                    ('single-permission', '!'), ('single-question', '?')]
        if wanted is None:
            for label, marker in [('done', '✓'), ('idle', '·'), ('error', '×')]:
                expected += [('split-' + label, marker), ('single-' + label, marker)]
        p.until(lambda: finder_state(p)['matchCount'] == len(expected),
                'attention rows including collapsed single panes: ' + repr(wanted))
        state = finder_state(p)
        if wanted is not None: assert state['query'] == '^! | ^?', state
        labels = [row['text'] for row in state['matches']]
        for label, marker in expected:
            matches = [line for line in labels if label in line]
            assert len(matches) == 1 and matches[0].startswith(marker + ' '), (label, labels)
        excluded = ['working'] + (['done', 'idle', 'error'] if wanted is not None else [])
        assert all('single-' + label not in line and 'split-' + label not in line
                   for label in excluded for line in labels), labels
        # A waiting program can resume while another starts asking a question.
        # The snapshot replacement must replace the cached marker set as well.
        p.snapshot['metadata']['block:selected']['program_status']['records'][0]['state'] = 'working'
        incoming = p.snapshot['metadata']['block:split-working']['program_status']['records'][0]
        incoming.update(state='blocked', kind='question')
        write_json(p.snapshot_path, p.snapshot)
        p.until(lambda: any('split-working' in row['text'] for row in finder_state(p)['matches']),
                'new waiting program in live attention rows')
        updated = finder_state(p)
        assert updated['matchCount'] == len(expected), updated
        assert not any('selected-pane' in row['text'] for row in updated['matches']), updated
        # Both row shapes must still activate the precise native block.
        label, block = ('single-permission', 'block:single-permission') if raw else ('split-question', 'block:split-question')
        p.query(label)
        p.until(lambda: finder_state(p)['matchCount'] == 1, 'exact attention row selection')
        p.send(b'\r')
        record = p.finish(cancel=False)
        assert record['outcome'] == 'select' and record['target']['block_id'] == block, record
        assert not p.calls('create'), 'status filters must never create a session'
        print(json.dumps({'attention_raw': raw, 'states': wanted or 'default', 'matched': len(expected),
                          'selected_block': block, 'live_state_change': True}), flush=True)
    finally: p.close()
"###;

const THEME_PROBE: &str = r###"
import subprocess

def theme_colors(launch):
    result = {}
    for argument in launch['args']:
        if argument.startswith('--color='):
            for item in argument[len('--color='):].split(','):
                key, _, value = item.partition(':')
                result[key] = value
    return result

def assert_theme(launch, profile, danger=False):
    assert launch['theme'] == profile, 'helper lost resolved profile: ' + repr(launch)
    colors = theme_colors(launch)
    assert colors['bg'] == '-1' and colors['preview-bg'] == '-1', colors
    if profile == 'terminal':
        assert colors['fg+'] == '-1:regular:bold', colors
        assert colors['bg+'] == '-1', colors
        assert colors['hl+'] == '#e78a4e:bold', colors
        assert colors['prompt'] == ('1' if danger else '#e78a4e'), colors
        assert colors['pointer'] == '#e78a4e', colors
    else:
        assert colors['fg+'] == '#ddc7a1:regular:bold' and colors['bg+'] == '#32302f', colors
        assert colors['prompt'] == ('#ea6962' if danger else '#d8a657'), colors
    return colors

def check_list_profiles(p):
    # A read-only tmux fixture exercises backend resolution without using or
    # starting a tmux server. Each response is the collector's single batch.
    u = '\x1f'
    sections = [
        u.join(['$1', 'theme-session', '0', '1', '', str(p.root)]),
        u.join(['$1', '@1', 'theme-session', '0', 'theme-window', '1', 'sh', str(p.root), '1', '0', '']),
        u.join(['$1', '@1', '%1', 'theme-session', '0', '0', '1', 'sh', str(p.root), '0', '1', '%1', 'theme-pane', '']),
        u.join(['theme-session', '0', '0', 'fixture', 'fixture']), '',
    ]
    tmux = p.root / 'tmux'
    tmux.write_text('#!' + sys.executable + '\nimport sys\nassert sys.argv[1] == "list-sessions", sys.argv\nsys.stdout.write(' + repr('\x1e'.join(sections)) + ')\n')
    tmux.chmod(0o700)
    for backend, configured, terminal in [('rex', None, True), ('rex', 'auto', True), ('rex', 'warm', False),
                                          ('tmux', None, False), ('tmux', 'auto', False), ('tmux', 'terminal', True)]:
        environment = dict(p.environment)
        environment.pop('INTERDIMUX_THEME', None)
        if configured is not None: environment['INTERDIMUX_THEME'] = configured
        command = [binary, 'list', '--backend', backend]
        if backend == 'rex': command += ['--client', 'client:origin', '--session', 'session:origin',
                                        '--window', 'window:origin', '--block', 'block:origin',
                                        '--snapshot', str(p.snapshot_path)]
        output = subprocess.run(command, env=environment, capture_output=True, timeout=10)
        assert output.returncode == 0, output.stderr
        assert output.stdout, (backend, configured)
        has_warm_primary = b'\x1b[38;2;212;190;152m' in output.stdout
        assert has_warm_primary != terminal, (backend, configured, output.stdout)

for configured, profile in [(None, 'terminal'), ('warm', 'warm')]:
    p = Picker(theme=configured)
    try:
        colors = assert_theme(p.top_launches()[0], profile)
        assert colors['nomatch'] == ('-1' if profile == 'terminal' else '#7c6f64') + ':strip:dim', colors
        p.query()
        for key, prompt in [(b'\x05', 'Rename'), (b'\x18', 'Confirm'), (b'\x0f', 'Directories'),
                            (b'\x1bj', 'Jobs'), (b'\x07', 'Actions')]:
            assert_theme(p.dialog(key, prompt), profile, danger=prompt == 'Confirm')
            p.send(b'\x1b'); p.pump(.15)
        # Scopes change the matching fields, not the selected-row attributes.
        for _ in range(5): p.send(b'\x1d'); p.pump(.06)
        assert_theme(p.top_launches()[0], profile)
        helper_environment = dict(p.environment, INTERDIMUX_THEME=profile,
                                  FZF_PREVIEW_COLUMNS='60', FZF_PREVIEW_LINES='14')
        for arguments in [['preview', 'imux:0'], ['dir-preview', str(p.root)]]:
            preview = subprocess.run([binary, 'ui', str(p.root / 'ui' / 'c'), *arguments],
                                     env=helper_environment, capture_output=True, timeout=10)
            assert preview.returncode == 0, preview.stderr
            accent = b'\x1b[1;38;2;231;138;78m' if profile == 'terminal' else b'\x1b[1;38;2;216;166;87m'
            assert accent in preview.stdout, (profile, arguments, preview.stdout)
        if configured is None: check_list_profiles(p)
        assert not p.calls('rename') and not p.calls('close'), p.requests
        p.stable(); p.finish()
        print(json.dumps({'theme': profile, 'surfaces': ['main', 'rename', 'confirm', 'directories', 'jobs', 'actions', 'previews']}), flush=True)
    finally: p.close()

# Direct commands travel through run_mode instead of pick's run entry point.
for mode, configured, profile in [('dashboard', None, 'terminal'), ('dashboard', 'warm', 'warm'),
                                  ('dirs', 'auto', 'terminal')]:
    p = Picker(mode=mode, theme=configured, direct=True)
    try:
        for launch in p.launches(): assert_theme(launch, profile)
        p.finish()
        print(json.dumps({'theme': profile, 'direct_mode': mode}), flush=True)
    finally: p.close()
"###;

fn run_pty_probe(code: &str) {
    let Ok(python) = Command::new("python3").arg("--version").output() else {
        eprintln!("Python 3 unavailable; skipping action PTY coverage");
        return;
    };
    if !python.status.success() {
        return;
    }
    let Ok(version) = Command::new("fzf").arg("--version").output() else {
        eprintln!("fzf unavailable; skipping action PTY coverage");
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
        eprintln!("fzf 0.74+ required; skipping action PTY coverage");
        return;
    }
    let fzf = Command::new("python3")
        .args(["-c", "import shutil; print(shutil.which('fzf'))"])
        .output()
        .unwrap();
    let fzf = String::from_utf8(fzf.stdout).unwrap();
    let probe = format!("{}\n{}", include_str!("terminal_screen.py"), code);
    let output = Command::new("python3")
        .args(["-c", &probe, env!("CARGO_BIN_EXE_imux"), fzf.trim()])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "Action PTY probe failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    eprintln!("{}", String::from_utf8_lossy(&output.stdout));
}

#[test]
fn shared_actions_keep_fzf_alive_and_use_only_hosted_native_ipc() {
    run_pty_probe(PROBE);
}

#[test]
fn native_themes_follow_the_backend_through_helpers_and_direct_modes() {
    let definitions = PROBE.split("scenario('live-typing-raw'").next().unwrap();
    run_pty_probe(&format!("{definitions}\n{THEME_PROBE}"));
}

#[test]
fn native_attention_states_match_real_fzf_for_collapsed_and_split_rows() {
    let definitions = PROBE.split("scenario('live-typing-raw'").next().unwrap();
    run_pty_probe(&format!("{definitions}\n{AGENTS_PROBE}"));
}
