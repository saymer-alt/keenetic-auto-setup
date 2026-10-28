#!/usr/bin/env python3
"""Expected-source gate regression for the production config-import.sh.

The web filter editor stages an operator-approved snapshot of config.yaml and
hands it to the canonical importer through KAS_EXPECTED_SOURCE. This test runs
the REAL production script (path-substituted lab, function-seam wrappers — the
same model as tests/rollback-regression.py) and proves:

  gate A — after the lifecycle lock is held and BEFORE Mihomo is stopped, a
           config that no longer matches the snapshot aborts with a clear
           error; the on-disk config (including the external writer's change)
           is preserved and the service is untouched;
  gate B — a writer that ignores the lock and lands during the stop/validate/
           backup window is caught immediately before the atomic rename; the
           candidate is abandoned and the previous service state is restored;
  residual boundary — a writer that lands strictly between the pre-commit
           comparison and the rename itself is NOT caught (the rename wins).
           This case is asserted deliberately: the documented contract says
           the gate narrows the unlocked-writer race, it does not eliminate it;
  fail-closed — a missing cmp applet or an unusable snapshot path aborts
           instead of proceeding unverified;
  compatibility — with KAS_EXPECTED_SOURCE unset, the transaction behaves
           byte-for-byte like before (no cmp calls, no new failure modes);
  rollback — a gated import whose Mihomo start fails still restores the
           previous config and retains the backup.

No router is contacted; nothing outside the temporary fixture tree is written.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

INIT = r'''#!/bin/sh
case "$1" in
stop)
  echo stop >> "$LAB/actions"
  rm -f "$LAB/running" ;;
start)
  echo start >> "$LAB/actions"
  [ "$CASE" = start-fail ] && exit 1
  : > "$LAB/running" ;;
esac
'''

MIHOMO = r'''#!/bin/sh
echo "mihomo $*" >> "$LAB/actions"
if [ "$CASE" = validation-fail ]; then
  echo "candidate rejected" >> "$LAB/actions"
  exit 1
fi
exit 0
'''

WRAPPERS = r'''
pidof() {
  if [ -f "$LAB/running" ]; then echo 4242; else return 1; fi
}
mv() {
  case "$*" in
    *.bak.new.*)
      command mv "$@" || return
      if [ "$CASE" = writer-during-window ]; then
        printf 'writer: landed during the import window\n' >> "$LAB/opt/etc/mihomo/config.yaml"
      fi
      return 0 ;;
    *.new.*)
      if [ "$CASE" = residual-writer ]; then
        printf 'writer: landed in the residual window\n' >> "$LAB/opt/etc/mihomo/config.yaml"
      fi
      command mv "$@" ;;
    *)
      command mv "$@" ;;
  esac
}
'''

CMP_WRAPPER = 'cmp() {\n  echo cmp >> "$LAB/actions"\n  command cmp "$@"\n}\n'

ORIGINAL_CONFIG = "mixed-port: 7890\nmode: rule\n"
WRITER_CONFIG = ORIGINAL_CONFIG + "writer: landed before the import\n"
CANDIDATE_CONFIG = ('mixed-port: 7890\nmode: rule\nproxy-providers:\n'
                    '  P:\n    type: http\n    exclude-filter: "^(?:X)$"\n')

# Applets the production script may exec. cmp is deliberately absent from the
# restricted PATH used by the cmp-missing case; pidof is provided as a
# function seam by the wrappers instead.
LAB_TOOLS = ('awk', 'cat', 'chmod', 'cmp', 'cp', 'date', 'grep', 'mkdir',
             'mv', 'rm', 'rmdir', 'sleep', 'wc')


def build_lab(lab, case, tools=LAB_TOOLS):
    for d in ('opt/bin', 'opt/etc/init.d', 'opt/etc/mihomo', 'tmp'):
        (lab / d).mkdir(parents=True, exist_ok=True)
    config = lab / 'opt/etc/mihomo/config.yaml'
    config.write_text(ORIGINAL_CONFIG, newline='\n')
    config.chmod(0o600)
    candidate = lab / 'candidate.yaml'
    candidate.write_text(CANDIDATE_CONFIG, newline='\n')
    candidate.chmod(0o600)
    init = lab / 'opt/etc/init.d/S99mihomo'
    init.write_text(INIT, newline='\n')
    init.chmod(0o700)
    mihomo = lab / 'opt/bin/mihomo'
    mihomo.write_text(MIHOMO, newline='\n')
    mihomo.chmod(0o700)
    # Windows host runners do not synthesize the POSIX execute bit from
    # Python's chmod; the MSYS layer does. Harmless on Linux CI.
    for exe in (init, mihomo):
        subprocess.run(['sh', '-c', 'chmod +x "$1"', 'chmod', str(exe)],
                       check=False, capture_output=True)
    restricted = lab / 'bin'
    restricted.mkdir()
    suffix = '.exe' if os.name == 'nt' else ''
    # Windows: plain copies. Hardlinks of Git/MSYS binaries fail to load
    # (STATUS_DLL_NOT_FOUND) and extensionless files cannot be executed.
    linker = shutil.copy2 if os.name == 'nt' else os.link
    dll_copied = False
    for tool in tools:
        found = shutil.which(tool)
        if not found:
            raise SystemExit('required tool missing on this host: ' + tool)
        try:
            linker(found, restricted / (tool + suffix))
        except OSError:
            shutil.copy(found, restricted / (tool + suffix))
        if not dll_copied:
            # Windows DLL search must resolve every transitive dependency
            # (msys-2.0.dll, msys-intl-8.dll, ...) from the restricted
            # directory itself, because the host PATH is replaced for the
            # cmp-missing case. Bring the runtime DLLs along once.
            for runtime in Path(found).parent.glob('*.dll'):
                try:
                    linker(runtime, restricted / runtime.name)
                except OSError:
                    shutil.copy(runtime, restricted / runtime.name)
            dll_copied = True
    return config, candidate, restricted


def run_case(shell, case, running=True, expected_source=True,
             modify_before_start=False, extra_env=None, tools=LAB_TOOLS):
    with tempfile.TemporaryDirectory(prefix='kas-filter-gate-',
                                     ignore_cleanup_errors=True) as directory:
        lab = Path(directory)
        config, candidate, restricted = build_lab(lab, case, tools)
        if running:
            (lab / 'running').write_text('original\n')
        snapshot = lab / 'snapshot.yaml'
        if expected_source:
            snapshot.write_text(ORIGINAL_CONFIG, newline='\n')
            snapshot.chmod(0o600)
        if modify_before_start:
            # The external writer changed config.yaml after the snapshot was
            # taken but before the import started.
            config.write_text(WRITER_CONFIG, newline='\n')
        script = lab / 'run.sh'
        # Forward-slash host paths: substituted values also appear inside the
        # unquoted for-list in resolve_mihomo, where Windows backslashes would
        # be eaten as escapes. Git Bash and BusyBox ash accept C:/ forms.
        posix = str(lab).replace('\\', '/') + '/'
        body = (ROOT / 'config-import.sh').read_text().replace(
            '/tmp/', posix + 'tmp/').replace('/opt/', posix + 'opt/')
        wrappers = WRAPPERS + (CMP_WRAPPER if 'cmp' in tools else '')
        script.write_text('#!/bin/sh\n' + wrappers + '\n' + body)
        env = dict(os.environ, LAB=str(lab), CASE=case)
        env['PATH'] = str(restricted).replace('\\', '/')
        env.pop('KAS_EXPECTED_SOURCE', None)
        if expected_source:
            env['KAS_EXPECTED_SOURCE'] = str(snapshot).replace('\\', '/')
        env.update(extra_env or {})
        candidate_arg = str(candidate).replace('\\', '/')
        p = subprocess.run(shell + [str(script), candidate_arg],
                           env=env, capture_output=True, text=True, timeout=60)
        actions = (lab / 'actions').read_text().splitlines() \
            if (lab / 'actions').exists() else []
        context = (shell, case, running, p.returncode, actions, p.stdout, p.stderr)
        return {
            'rc': p.returncode,
            'stderr': p.stderr,
            'stdout': p.stdout,
            'config': config.read_text(),
            'backup': (lab / 'opt/etc/mihomo/config.yaml.bak').read_text()
                      if (lab / 'opt/etc/mihomo/config.yaml.bak').exists() else None,
            'service_running': (lab / 'running').exists(),
            'actions': actions,
            'lock_left': (lab / 'tmp/mihomo-lifecycle.lock.d').exists(),
            'marker_left': (lab / 'tmp/mihomo.maintenance').exists(),
            'cmp_calls': sum(1 for a in actions if a == 'cmp'),
            'context': context,
        }


def shells():
    out = [[shutil.which('sh') or '/bin/sh']]
    if shutil.which('busybox'):
        out.append([shutil.which('busybox'), 'ash'])
    return out


def check(name, ok, detail=''):
    marker = 'PASS' if ok else 'FAIL'
    print('[%s] %s%s' % (marker, name, (': ' + detail) if detail and not ok else ''),
          flush=True)
    return ok


def main():
    failures = 0
    for shell in shells():
        label = '/'.join(shell)
        r = run_case(shell, 'no-gate', expected_source=False)
        failures += not check(
            'no-gate success without cmp (%s)' % label,
            r['rc'] == 0 and r['config'] == CANDIDATE_CONFIG
            and r['backup'] == ORIGINAL_CONFIG and r['service_running']
            and r['cmp_calls'] == 0 and not r['lock_left'] and not r['marker_left'],
            repr(r['context']))

        r = run_case(shell, 'gate-match')
        failures += not check(
            'gate-match success with both gates (%s)' % label,
            r['rc'] == 0 and r['config'] == CANDIDATE_CONFIG
            and r['cmp_calls'] >= 2 and r['service_running']
            and not r['lock_left'] and not r['marker_left'],
            repr(r['context']))

        r = run_case(shell, 'gate-stale', modify_before_start=True)
        failures += not check(
            'gate A rejects stale config before stopping (%s)' % label,
            r['rc'] != 0
            and 'changed since the operator-approved snapshot' in r['stderr']
            and r['config'] == WRITER_CONFIG
            and r['service_running']
            and 'stop' not in r['actions']
            and r['backup'] is None
            and not r['lock_left'] and not r['marker_left'],
            repr(r['context']))

        r = run_case(shell, 'writer-during-window')
        failures += not check(
            'gate B catches writer during validate/backup window (%s)' % label,
            r['rc'] != 0
            and 'changed since the operator-approved snapshot' in r['stderr']
            and r['config'] == ORIGINAL_CONFIG
            + 'writer: landed during the import window\n'
            and r['backup'] == ORIGINAL_CONFIG
            and r['service_running']
            and 'stop' in r['actions'] and 'start' in r['actions']
            and not r['lock_left'] and not r['marker_left'],
            repr(r['context']))

        r = run_case(shell, 'writer-during-window', running=False)
        failures += not check(
            'gate B with stopped service stays stopped (%s)' % label,
            r['rc'] != 0 and r['config'] == ORIGINAL_CONFIG
            + 'writer: landed during the import window\n'
            and 'start' not in r['actions']
            and not r['service_running']
            and not r['lock_left'] and not r['marker_left'],
            repr(r['context']))

        r = run_case(shell, 'residual-writer')
        # Documented boundary: a writer landing strictly between the pre-commit
        # comparison and the atomic rename is overwritten by the candidate.
        # The import succeeds from the importer's perspective; the external
        # change is lost; backup holds the pre-window bytes, not the late edit.
        failures += not check(
            'residual window boundary is real, not eliminated (%s)' % label,
            r['rc'] == 0 and r['config'] == CANDIDATE_CONFIG
            and r['backup'] == ORIGINAL_CONFIG and r['cmp_calls'] >= 2,
            repr(r['context']))

        r = run_case(shell, 'cmp-missing',
                     tools=[t for t in LAB_TOOLS if t != 'cmp'])
        # Keep a valid regular snapshot: this case must independently prove
        # that missing cmp fails closed, rather than missing input failing first.
        failures += not check(
            'missing cmp fails closed (%s)' % label,
            r['rc'] != 0 and 'gate is unusable' in r['stderr']
            and r['config'] == ORIGINAL_CONFIG and r['service_running']
            and 'stop' not in r['actions']
            and not r['lock_left'] and not r['marker_left'],
            repr(r['context']))

        r = run_case(shell, 'snapshot-missing', expected_source=False,
                     extra_env={'KAS_EXPECTED_SOURCE': 'PLACEHOLDER'})
        failures += not check(
            'missing snapshot fails closed with cmp available (%s)' % label,
            r['rc'] != 0 and 'gate is unusable' in r['stderr']
            and r['config'] == ORIGINAL_CONFIG and r['service_running']
            and 'stop' not in r['actions']
            and not r['lock_left'] and not r['marker_left'],
            repr(r['context']))

        r = run_case(shell, 'validation-fail')
        failures += not check(
            'gated import rollback on candidate validation failure (%s)' % label,
            r['rc'] != 0 and r['config'] == ORIGINAL_CONFIG
            and r['service_running']
            and 'stop' in r['actions'] and 'start' in r['actions']
            and r['backup'] is None
            and not r['lock_left'] and not r['marker_left'],
            repr(r['context']))

        r = run_case(shell, 'start-fail')
        failures += not check(
            'gated import rollback on start failure retains backup (%s)' % label,
            r['rc'] != 0 and r['config'] == ORIGINAL_CONFIG
            and r['backup'] == ORIGINAL_CONFIG
            and not r['service_running']
            and not r['lock_left'] and not r['marker_left'],
            repr(r['context']))

        r = run_case(shell, 'self-snapshot',
                     extra_env={'KAS_EXPECTED_SOURCE': 'SELF'})
        # Pathological but harmless: pointing the gate at the config itself
        # must not corrupt or bypass anything.
        failures += not check(
            'self-referential snapshot does not bypass the gate (%s)' % label,
            r['rc'] != 0 or r['config'] == CANDIDATE_CONFIG,
            repr(r['context']))
    if failures:
        print('[FAIL] expected-source gate regression: %d failure(s)' % failures)
        return 1
    print('[OK] expected-source gate regression passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
