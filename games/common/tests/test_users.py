#!/usr/bin/env python3
"""Exercise shared accounts against both games' real account and save implementations."""
import os
import plistlib
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
COMMON = ROOT / 'games/common'


def main():
    with tempfile.TemporaryDirectory(prefix='mng-users-') as folder:
        base = Path(folder) / 'MacNativeGames'
        accounts = base / 'Accounts'
        env = {k: v for k, v in os.environ.items() if not k.startswith(('TOTK_', 'MNG_'))}
        env['MNG_USERS_DIR'] = str(accounts)
        binaries = {}
        for game in ('tomodachi', 'totk'):
            runtime = ROOT / 'games' / game / 'runtime'
            binary = Path(folder) / game
            command = ['xcrun', 'clang', '-std=c11', '-fobjc-arc', '-I', str(runtime),
                       str(COMMON / 'tests/fixture.m'), str(COMMON / 'users.m'),
                       str(runtime / 'account.c'), str(runtime / 'fs_host.c'), '-framework', 'Cocoa', '-o', str(binary)]
            if game == 'totk': command.insert(4, '-DTEST_TOTK=1')
            subprocess.run(command, check=True)
            binaries[game] = binary

        def run(game, *args, check=True):
            return subprocess.run([str(binaries[game]), *map(str, args)], env=env, text=True,
                                  capture_output=True, check=check)

        def users(game):
            return dict(line.split('\t', 1) for line in run(game, 'list').stdout.splitlines())

        custom_profile = Path(folder) / 'elsewhere/custom-profile'
        custom_profile.mkdir(parents=True)
        custom_local, imported_uid = (f'{n:032x}' for n in (0x404, 0x505))
        legacy_users = f'{custom_local}\tLocal\n*{imported_uid}\tImported\n'
        (custom_profile / 'users.txt').write_text(legacy_users)
        custom_env = env | {
            'MNG_USERS_DIR': str(Path(folder) / 'custom-accounts'),
            'MNG_USER_PROFILE': str(custom_profile),
        }
        result = subprocess.run([str(binaries['tomodachi']), 'list'], env=custom_env, text=True,
                                capture_output=True, check=True)
        assert dict(line.split('\t', 1) for line in result.stdout.splitlines()) == {
            'default': 'Local', imported_uid: 'Imported'}
        assert (custom_profile / 'users.txt').read_text() == legacy_users

        run('tomodachi', 'single')  # one default user does not create a window
        assert users('totk') == {'default': 'Local'}
        zelda, tomo = base / 'TOTK/profile', base / 'Tomodachi/profile'
        zelda.mkdir(parents=True); tomo.mkdir(parents=True)
        zelda_uid, tomo_uid, friend_uid = (f'{n:032x}' for n in (0x101, 0x202, 0x303))
        (zelda / 'users.txt').write_text(f'{zelda_uid}\tLocal\n*{friend_uid}\tFriend\n')
        (tomo / 'account.uid').write_bytes(struct.pack('<QQ', 0x202, 0))
        for profile, uid, marker in ((zelda, zelda_uid, 'zelda-old'), (zelda, friend_uid, 'friend-old'), (tomo, tomo_uid, 'tomo-old')):
            save = profile / 'save' / uid; save.mkdir(parents=True); (save / 'marker').write_text(marker)
        assert users('tomodachi') == {'default': 'Local', friend_uid: 'Friend'}
        if '--ui' in sys.argv:
            bundle = Path(folder) / 'UserSelectionProbe.app/Contents'
            (bundle / 'MacOS').mkdir(parents=True)
            probe = bundle / 'MacOS/Probe'; shutil.copy2(binaries['tomodachi'], probe)
            (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'org.macnativegames.users.probe', 'CFBundleExecutable': 'Probe', 'CFBundlePackageType': 'APPL'}))
            result = subprocess.run([str(probe), 'probe-select'], env=env, text=True, capture_output=True, timeout=15)
            assert result.returncode == 0, result.stdout + result.stderr
            result = subprocess.run([str(probe), 'probe-manage'], env=env, text=True, capture_output=True, timeout=15)
            assert result.returncode == 0, result.stdout + result.stderr
        run('totk', zelda, 'default', 'Local', 'read', 'zelda-old')
        run('totk', zelda, friend_uid, 'Friend', 'read', 'friend-old')
        run('tomodachi', tomo, 'default', 'Local', 'read', 'tomo-old')
        run('totk', zelda, 'default', 'Local', 'add-zelda', 'Alice')
        shared = users('tomodachi'); alice = next(uid for uid, name in shared.items() if name == 'Alice')
        assert users('totk') == shared
        for game, profile, value in (('totk', zelda, 'zelda-alice'), ('tomodachi', tomo, 'tomo-alice')):
            run(game, profile, alice, 'Alice', 'absent', '-')
            assert run(game, profile, alice, 'Alice', 'write', value).stdout.strip() == alice
            run(game, profile, alice, 'Alice', 'read', value)
        run('totk', zelda, 'default', 'Local', 'read', 'zelda-old')
        run('totk', zelda, friend_uid, 'Friend', 'read', 'friend-old')
        run('tomodachi', tomo, 'default', 'Local', 'read', 'tomo-old')
        run('totk', zelda, alice, 'Alice', 'archive-current', '-')
        assert 'Alice' not in users('tomodachi').values()
        assert dict(line.split('\t', 1) for line in run('totk', 'archived').stdout.splitlines()) == {alice: 'Alice'}
        assert run('totk', 'archive', 'default', check=False).returncode != 0
        assert run('tomodachi', 'add', 'Alice', check=False).returncode != 0
        run('tomodachi', 'restore', alice)
        run('totk', zelda, alice, 'Alice', 'read', 'zelda-alice')
        run('tomodachi', tomo, alice, 'Alice', 'read', 'tomo-alice')
        assert (tomo / 'account.uid').read_bytes() == struct.pack('<QQ', 0x202, 0)
        assert run('totk', 'add', 'Alice', check=False).returncode != 0
        assert run('tomodachi', 'add', 'x' * 32, check=False).returncode != 0
        pending = [subprocess.Popen([str(binaries[game]), 'add', name], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                   for game, name in (('totk', 'Bob'), ('tomodachi', 'Carol'))]
        for child in pending:
            child.communicate(timeout=20); assert child.returncode == 0
        assert set(users('totk').values()) == {'Local', 'Friend', 'Alice', 'Bob', 'Carol'}
        store = accounts / 'users.plist'; store.write_bytes(b'corrupt')
        assert run('tomodachi', 'list', check=False).returncode != 0 and store.read_bytes() == b'corrupt'
        print('PASS: shared users, legacy import, singleton startup, concurrent additions, safe removal/restoration and per-game saves')


if __name__ == '__main__':
    main()
