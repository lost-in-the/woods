"""Compare two exact checkouts; sample real pinned-old/new reload RSS on Linux.

Usage: python3 bench/lexical_postings_compare.py BASELINE FINAL OUTPUT_DIR
Run with Ruby/Bundler available on PATH. Both checkouts need a compatible bundle.
Each variant/repetition uses separate fresh processes for direct-query lifecycle
and published reload, preventing query/retention experiments from priming reload.
The worker comes from this script's directory, with each checkout's library loaded.
By default both checkouts must be clean. --allow-staged records an exact staged
tree for preliminary measurements when a commit cannot be made; it does not
establish validation of a committed final head. Unstaged/untracked files refuse.
RSS peaks are sampled lower bounds, not sums of independent process heaps.
"""
import hashlib
import json
import pathlib
import subprocess
import sys
import threading
import time

allow_staged = '--allow-staged' in sys.argv
arguments = [arg for arg in sys.argv[1:] if arg != '--allow-staged']
baseline, final, destination = arguments
output = pathlib.Path(destination).resolve()
output.mkdir(parents=True, exist_ok=True)
worker = pathlib.Path(__file__).resolve().with_name('lexical_postings_lifecycle.rb')


def checkout_identity(root):
    status = subprocess.check_output(['git', 'status', '--porcelain'], cwd=root, text=True)
    subprocess.check_call(['git', 'diff', '--exit-code'], cwd=root, stdout=subprocess.DEVNULL)
    untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard'], cwd=root, text=True)
    if untracked or (status and not allow_staged):
        raise RuntimeError(f'Commit the candidate before measuring: {root}: {status}')
    return {
        'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
        'tree': subprocess.check_output(['git', 'write-tree'], cwd=root, text=True).strip(),
        'status': status
    }


def run_worker(root, count, repeat, variant, mode):
    command = ['bundle', 'exec', 'ruby', '-Ilib', str(worker), str(count), mode]
    log_path = output / f'{count}-{repeat}-{variant}-{mode}.log'
    with log_path.open('w') as log:
        process = subprocess.Popen(command, cwd=root, stdout=subprocess.PIPE, stderr=log, text=True)
        active = threading.Event()
        observed = {'peak': 0, 'samples': 0}

        def sample():
            while process.poll() is None:
                if active.is_set():
                    try:
                        status = pathlib.Path(f'/proc/{process.pid}/status').read_text().splitlines()
                        rss = next(line for line in status if line.startswith('VmRSS:'))
                        observed['peak'] = max(observed['peak'], int(rss.split()[1]))
                        observed['samples'] += 1
                    except (OSError, StopIteration):
                        pass
                time.sleep(0.001)

        sampler = threading.Thread(target=sample)
        sampler.start()
        result = None
        for line in process.stdout:
            log.write(line)
            row = json.loads(line)
            if row['phase'] == 'reload_start':
                active.set()
            if row['phase'] == 'reload_end':
                active.clear()
            if row['phase'] == 'result':
                result = row
        code = process.wait()
        sampler.join()
    if code or result is None or (mode == 'reload' and not observed['samples']):
        raise RuntimeError((variant, count, code, str(log_path), observed))
    if mode == 'reload':
        result.update(reload_peak_rss_kib=observed['peak'], rss_samples=observed['samples'])
    return result


roots = {name: pathlib.Path(path).resolve() for name, path in [('baseline', baseline), ('final', final)]}
identities = {name: checkout_identity(root) for name, root in roots.items()}
results = []
for count in [1000, 10000]:
    for repeat in range(3):
        variants = ['baseline', 'final'] if repeat % 2 == 0 else ['final', 'baseline']
        for variant in variants:
            root = roots[variant]
            direct = run_worker(root, count, repeat, variant, 'direct')
            reload = run_worker(root, count, repeat, variant, 'reload')
            if checkout_identity(root) != identities[variant]:
                raise RuntimeError(f'Checkout moved during measurement: {root}')
            source = root / 'lib/woods/retrieval/lexical_index.rb'
            result = dict(direct, **reload)
            result.update(variant=variant, repeat=repeat, checkout=str(root),
                          head=identities[variant]['head'], tree=identities[variant]['tree'],
                          staged_candidate=bool(identities[variant]['status']),
                          lexical_source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                          worker_sha256=hashlib.sha256(worker.read_bytes()).hexdigest(),
                          lock_sha256=hashlib.sha256((root / 'Gemfile.lock').read_bytes()).hexdigest())
            results.append(result)
            (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            print(variant, count, repeat, 'build', round(result['build_ms'], 2),
                  'scoped', round(result['packaged_scoped_ms'], 2), 'reload peak KiB',
                  result['reload_peak_rss_kib'], flush=True)
for count in [1000, 10000]:
    rows = [row for row in results if row['count'] == count]
    expected = rows[0]['digests']
    if any(row['digests'] != expected for row in rows):
        raise RuntimeError(f'Ordered candidate/score/metadata digests differ at {count}')
print('All ordered result digests match across variants and repetitions.')
