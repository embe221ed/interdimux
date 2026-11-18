#!/usr/bin/env python3
"""Compare release helpers on bounded Projects scans with real local directories."""
import argparse
from contextlib import ExitStack
import json
from pathlib import Path
import statistics
import subprocess
import tempfile

from benchmark import Protocol, stop_owned


def workspace(root, directory_count, session_count):
    projects = root / 'projects'
    projects.mkdir(parents=True)
    snapshot = dict(version=1, local_host_id='local', host_id='local', sessions=[],
                    views={}, metadata={}, session_paths={})
    occupied = set()
    for i in range(directory_count):
        path = projects / f'project-{i:03}'
        path.mkdir()
        (path / 'Cargo.toml').touch()
        if i >= session_count:
            continue
        occupied.add(str(path))
        sid, wid, bid = f'session:{i}', f'window:{i}', f'block:{i}'
        snapshot['sessions'].append({'session_id': sid, 'label': f'renamed-{i}'})
        block = {'block_id': bid, 'creator_name': 'com.superlogical.terminal', 'host_id': 'local'}
        window = {'window_id': wid, 'label': 'Shell', 'focused_block_id': bid, 'layers': [{'blocks': [block]}]}
        snapshot['views'][sid] = {'session_id': sid, 'active_window_id': wid, 'windows': [window]}
        snapshot['metadata'][bid] = {'foreground': {'name': 'sh', 'cwd': str(path)}}
        snapshot['session_paths'][sid] = str(path)
    client = {'client_id': 'client:bench', 'info': {'kind': 'app', 'platform': 'macos'},
              'principal': {'kind': 'peer', 'transport': 'unix'}}
    reply = root / 'snapshot.json'
    reply.write_text(json.dumps({'clients': {'clients': [client]}, 'snapshot': snapshot}))
    rex = root / 'rex'
    rex.write_text('''#!/bin/sh
case " $* " in
  *" hosts list "*) echo '{"hosts":[]}'; exit ;;
esac
/bin/cat >/dev/null
exec /bin/cat "$IMUX_BENCHMARK_SNAPSHOT"
''')
    rex.chmod(0o700)
    return {'PATH': '/bin:/usr/bin', 'HOME': str(root), 'XDG_DATA_HOME': str(root / 'data'),
            'XDG_CONFIG_HOME': str(root / 'config'), 'INTERDIMUX_PROJECT_DIRS': str(projects),
            'INTERDIMUX_SHOW_DIRS': 'on', 'INTERDIMUX_USE_ZOXIDE': 'off',
            'INTERDIMUX_REX_BIN': str(rex), 'IMUX_BENCHMARK_SNAPSHOT': str(reply)}, occupied


def compare(helpers, rounds, directory_count, session_count):
    with tempfile.TemporaryDirectory(prefix='imux-project-bench-') as tmp, ExitStack() as stack:
        environment, occupied = workspace(Path(tmp).resolve(), directory_count, session_count)
        protocols = []
        samples = {label: [] for label in helpers}
        for label, path in helpers.items():
            process = stack.enter_context(subprocess.Popen([path, 'macos-serve'], env=environment,
                                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                          bufsize=0, start_new_session=True))
            stack.callback(stop_owned, process)
            protocol = Protocol(process)
            protocol.request('open', context={'client_id': 'client:bench'})
            protocols.append((label, protocol))
        for i in range(rounds + 1):
            order = protocols if i % 2 == 0 else reversed(protocols)
            for label, protocol in order:
                response, elapsed = protocol.request('directories', reset=True, query='')
                for row in response['rows']:
                    if row['kind'] != 'directory' or bool(row['current']) != (row['path'] in occupied):
                        raise RuntimeError(f'{label} returned an incorrect project association')
                if i:
                    samples[label].append({'ms': round(elapsed, 3), 'matches': response['matched']})
        return {'directories': directory_count, 'sessions': session_count, 'samples': samples,
                'medians': {name: {key: statistics.median(s[key] for s in series) for key in ('ms', 'matches')}
                            for name, series in samples.items()}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', action='append', required=True, metavar='LABEL=PATH')
    parser.add_argument('--rounds', type=int, default=8)
    args = parser.parse_args()
    helpers = {}
    for item in args.helper:
        label, sep, path = item.partition('=')
        if not label or not sep or label in helpers or not Path(path).is_file():
            parser.error('use a distinct label and existing executable path for each helper')
        helpers[label] = str(Path(path).resolve())
    if args.rounds < 1:
        parser.error('rounds must be positive')
    for directories, sessions in [(8, 1), (48, 24), (120, 96)]:
        print(json.dumps(compare(helpers, args.rounds, directories, sessions)), flush=True)


if __name__ == '__main__':
    main()
