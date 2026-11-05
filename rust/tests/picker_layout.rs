//! The first real fzf frame uses the float's PTY grid, including its footer.
#![cfg(unix)]

use std::process::Command;

const PROBE: &str = r###"
import errno, fcntl, json, os, pty, re, select, signal, struct, sys, tempfile, termios, time
from pathlib import Path

binary, fzf = sys.argv[1:]


def respond(fd, pending, data):
    pending += data
    end = 0
    for match in re.finditer(rb'\x1b\[([0-?]*[ -/]*)([@-~])', pending):
        parameters, final = match.groups()
        answer = None
        if final == b'n' and parameters == b'6': answer = b'\x1b[1;1R'
        elif final == b'c' and parameters.startswith(b'>'): answer = b'\x1b[>84;0;0c'
        elif final == b'c' and parameters in (b'', b'0'): answer = b'\x1b[?1;2c'
        elif final == b'p' and re.fullmatch(rb'\?[0-9]+\$', parameters): answer = b'\x1b['+parameters[:-1]+b';2$y'
        if answer: os.write(fd, answer)
        end = match.end()
    return pending[end:][-128:]

def probe(explicit_columns=None, gated=False, preview=False):
    with tempfile.TemporaryDirectory(prefix='imux-layout-') as temp:
        root = Path(temp)
        snapshot = {'version': 1, 'sessions': [{'session_id': 'session:origin', 'label': 'layout-project'}],
                    'views': {'session:origin': {'active_window_id': 'window:origin', 'windows': [{
                        'window_id': 'window:origin', 'label': 'layout-window', 'focused_block_id': 'block:origin',
                        'layers': [{'kind': 'tiled', 'blocks': [{'block_id': 'block:origin', 'label': 'layout-pane'}]}],
                    }]}}, 'errors': {}}
        (root/'snapshot.json').write_text(json.dumps(snapshot))
        if gated:
            (root/'ready.json').write_text(json.dumps({'version': 1, 'ready': False}))
        environment = dict(os.environ)
        for name in list(environment):
            if name.startswith(('INTERDIMUX_', 'REX_', 'FZF_')) or name in ('TMUX', 'TMUX_PANE'):
                environment.pop(name, None)
        environment.update({'TERM': 'xterm-256color', 'LINES': '9', 'COLUMNS': '20',
                            'INTERDIMUX_FZF_BIN': fzf, 'INTERDIMUX_REX_BIN': str(root/'missing-rex'),
                            'INTERDIMUX_USE_ZOXIDE': 'off'})
        if gated:
            # A marker before exec distinguishes “no fzf launched” from fzf
            # merely not having painted yet. This wrapper is test-only.
            wrapper = root/'fzf'
            wrapper.write_text('#!/bin/sh\n: > "$IMUX_FZF_LAUNCHED"\nexec "$IMUX_REAL_FZF" "$@"\n')
            wrapper.chmod(0o700)
            environment.update({'INTERDIMUX_FZF_BIN': str(wrapper),
                                'IMUX_FZF_LAUNCHED': str(root/'fzf-launched'), 'IMUX_REAL_FZF': fzf})
        if explicit_columns is not None: environment['INTERDIMUX_COLS'] = str(explicit_columns)
        if preview: environment['INTERDIMUX_PREVIEW'] = 'on'
        gate_read, gate_write = os.pipe()
        started = time.monotonic()
        child, master = pty.fork()
        if child == 0:
            os.close(gate_write)
            os.read(gate_read, 1)
            os.close(gate_read)
            command = [binary, 'pick', '--backend', 'rex', '--client', 'client:origin', '--session', 'session:origin',
                       '--window', 'window:origin', '--block', 'block:origin', '--picker-block', 'block:picker',
                       '--snapshot', str(root/'snapshot.json'), '--result', str(root/'result.json')]
            os.execve(binary, command, environment)
        os.close(gate_read)
        # Gate exec so the first ioctl is deterministic, rather than racing fzf.
        initial_rows = 12 if gated else 28
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', initial_rows, 120, 0, 0))
        os.write(gate_write, b'x'); os.close(gate_write)
        cursor, pending = Cursor(initial_rows), b''
        output = bytearray()
        resized, cancelled, status = False, False, None
        first_frame = b''
        released = not gated
        previous_request = None
        try:
            while time.monotonic()-started < 6:
                if preview:
                    try: request = json.loads((root/'request.json').read_text())
                    except (FileNotFoundError, json.JSONDecodeError): request = None
                    if request and request['id'] != previous_request:
                        previous_request = request['id']
                        assert request['operation'] == 'preview', request
                        (root/'response.tmp').write_text(json.dumps({'version': 1, 'id': request['id'], 'ok': True,
                                                                   'data': {'text': 'preview output'}}))
                        (root/'response.tmp').replace(root/'response.json')
                ready, _, _ = select.select([master], [], [], .01)
                if ready:
                    try: data = os.read(master, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO: break
                        raise
                    if not data: break
                    output.extend(data)
                    cursor.feed(data, (time.monotonic()-started)*1000)
                    pending = respond(master, pending, data)
                if gated and not released and time.monotonic()-started >= .15:
                    assert not (root/'fzf-launched').exists(), 'fzf launched while the hosted readiness gate was pending'
                    assert not cursor.anchors and b'layout-project' not in output, 'finder painted the provisional 12-row grid'
                    assert b'\x1b[?1049h' not in output, 'finder entered the alternate screen before native readiness'
                    # Simulate the GUI finishing ownership/font sizing before
                    # its atomic success record permits collection/rendering.
                    cursor.rows = 28
                    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 28, 120, 0, 0))
                    (root/'ready.tmp').write_text(json.dumps({'version': 1, 'ready': True}))
                    (root/'ready.tmp').replace(root/'ready.json')
                    released = True
                if cursor.anchors and not cursor.synchronized and not resized:
                    assert released, 'finder painted before readiness was published'
                    first_frame = bytes(output)
                    assert cursor.anchors[0]['row'] == 28, cursor.anchors
                    assert cursor.anchors[0]['tty_rows'] == 28, cursor.anchors
                    if preview:
                        assert b'^e rename' not in first_frame, 'initial footer ignored the preview pane width'
                    elif explicit_columns is None:
                        assert b'^e rename' in first_frame, 'initial footer used stale COLUMNS=20 instead of the 120-column PTY'
                    else:
                        assert b'^e rename' not in first_frame, 'explicit INTERDIMUX_COLS override was ignored'
                    cursor.rows = 36
                    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 36, 100, 0, 0))
                    os.killpg(child, signal.SIGWINCH)
                    resized = True
                if resized and not cursor.synchronized and any(anchor['row'] == 36 for anchor in cursor.anchors) and not cancelled:
                    os.write(master, b'\x1b')
                    cancelled = True
            end = time.monotonic()+2
            while time.monotonic() < end:
                found, child_status = os.waitpid(child, os.WNOHANG)
                if found:
                    status = child_status
                    break
                time.sleep(.005)
            else: raise AssertionError('picker did not exit')
            assert os.waitstatus_to_exitcode(status) == 0, repr(bytes(output[-1800:]))
            assert resized and cancelled, 'footer never anchored at first/final grid: '+repr(cursor.anchors)+'; tail='+repr(bytes(output[-1800:]))
            assert all(anchor['row'] == anchor['tty_rows'] for anchor in cursor.anchors), cursor.anchors
            assert json.loads((root/'result.json').read_text())['outcome'] == 'cancel'
            return {'explicit_columns': explicit_columns, 'hosted_ready_gate': gated, 'preview': preview, 'anchors': cursor.anchors}
        finally:
            if status is None:
                try: os.killpg(child, signal.SIGKILL)
                except ProcessLookupError: pass
            # Close before reaping: macOS may otherwise block in PTY teardown.
            os.close(master)
            if status is None:
                try: os.waitpid(child, 0)
                except ChildProcessError: pass

def narrow_probe():
    with tempfile.TemporaryDirectory(prefix='imux-narrow-') as temp:
        root = Path(temp)
        snapshot = {'version': 1,
            'sessions': [{'session_id': 'session:origin', 'label': 'session-' + 's'*90 + '-session-tail'}],
            'views': {'session:origin': {'active_window_id': 'window:origin', 'windows': [{
                'window_id': 'window:origin', 'label': 'Editor-' + 'w'*90 + '-window-tail', 'focused_block_id': 'block:origin',
                'layers': [{'kind': 'tiled', 'blocks': [{'block_id': 'block:origin', 'label': '日本語-' + 'p'*90 + '-pane-tail'}]}],
            }]}},
            'metadata': {'block:origin': {'foreground': {'name': 'COMMAND_NEEDLE', 'cwd': '/deep/' + 'path/'*20 + 'path-tail', 'pid': 0}}},
            'errors': {}}
        (root/'snapshot.json').write_text(json.dumps(snapshot))
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(('INTERDIMUX_', 'REX_', 'FZF_')) and key not in ('TMUX', 'TMUX_PANE')}
        environment.update({'TERM': 'xterm-256color', 'HOME': str(root), 'XDG_DATA_HOME': str(root/'data'),
                            'INTERDIMUX_FZF_BIN': fzf, 'INTERDIMUX_REX_BIN': str(root/'missing-rex'),
                            'INTERDIMUX_USE_ZOXIDE': 'off'})
        gate_read, gate_write = os.pipe()
        command = [binary, 'pick', '--backend', 'rex', '--client', 'client:origin', '--session', 'session:origin',
                   '--window', 'window:origin', '--block', 'block:origin', '--picker-block', 'block:picker',
                   '--snapshot', str(root/'snapshot.json'), '--result', str(root/'result.json')]
        child, master = pty.fork()
        if child == 0:
            os.close(gate_write); os.read(gate_read, 1); os.close(gate_read)
            os.execve(binary, command, environment)
        os.close(gate_read)
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 18, 64, 0, 0))
        os.write(gate_write, b'x'); os.close(gate_write)
        cursor, pending, status = Cursor(18, 64), b'', None
        queries = ['COMMAND_NEEDLE', 'pane-tail', 'window-tail', '日本語', 'session-tail']
        stage, checked, started = -1, [], time.monotonic()
        output = bytearray()
        try:
            while time.monotonic()-started < 8:
                if select.select([master], [], [], .01)[0]:
                    try: data = os.read(master, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO: break
                        raise
                    if not data: break
                    output.extend(data); cursor.feed(data, (time.monotonic()-started)*1000)
                    pending = respond(master, pending, data)
                body = cursor.visible(1, 17)
                if cursor.synchronized: continue
                if stage == -1 and any('Editor-' in row for row in body):
                    stage = 0; os.write(master, queries[stage].encode())
                elif 0 <= stage < len(queries):
                    # Exclude row zero: the prompt echo is not evidence that a
                    # matched suffix has actually become visible in the list.
                    if any(queries[stage] in row for row in body):
                        checked.append(queries[stage]); stage += 1
                        if stage == len(queries): os.write(master, b'\x1b')
                        else: os.write(master, b'\x15' + queries[stage].encode())
            end = time.monotonic()+2
            while time.monotonic() < end:
                found, child_status = os.waitpid(child, os.WNOHANG)
                if found:
                    status = child_status
                    break
                time.sleep(.005)
            else: raise AssertionError('narrow picker did not exit; matched: '+repr(checked)+'; grid: '+repr(cursor.visible()))
            assert os.waitstatus_to_exitcode(status) == 0, repr(bytes(output[-1500:]))
            assert checked == queries, 'invisible successful matches: '+repr(checked)+'; grid: '+repr(cursor.visible())
            assert json.loads((root/'result.json').read_text())['outcome'] == 'cancel'
            return {'narrow_columns': 64, 'visible_matches': checked}
        finally:
            if status is None:
                try: os.killpg(child, signal.SIGKILL)
                except ProcessLookupError: pass
            # Close before reaping: macOS may otherwise block in PTY teardown.
            os.close(master)
            if status is None:
                try: os.waitpid(child, 0)
                except ChildProcessError: pass

for explicit in (None, 80): print(json.dumps(probe(explicit)), flush=True)
print(json.dumps(probe(gated=True)), flush=True)
print(json.dumps(probe(preview=True)), flush=True)
print(json.dumps(narrow_probe()), flush=True)
"###;

#[test]
fn footer_starts_at_the_real_grid_bottom_and_follows_terminal_resizes() {
    let Ok(python) = Command::new("python3").arg("--version").output() else {
        eprintln!("Python 3 unavailable; skipping PTY layout coverage");
        return;
    };
    if !python.status.success() {
        return;
    }
    let Ok(version) = Command::new("fzf").arg("--version").output() else {
        eprintln!("fzf unavailable; skipping PTY layout coverage");
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
        eprintln!("fzf 0.74+ required; skipping PTY layout coverage");
        return;
    }
    let fzf = Command::new("python3")
        .args(["-c", "import shutil; print(shutil.which('fzf'))"])
        .output()
        .unwrap();
    let fzf = String::from_utf8(fzf.stdout).unwrap();
    let probe = format!("{}\n{}", include_str!("terminal_screen.py"), PROBE);
    let output = Command::new("python3")
        .args(["-c", &probe, env!("CARGO_BIN_EXE_imux"), fzf.trim()])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "PTY layout probe failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    eprintln!("{}", String::from_utf8_lossy(&output.stdout));
}
