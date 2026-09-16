#!/usr/bin/env python3
"""Offline provider migration for the menu-bar switch action."""
import argparse
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

TARGETS = {
    'official': ('openai', 'gpt-6-astra'),
    'deepseek': ('custom', 'deepseek-v4-pro'),
    'aliyun': ('aliyun', 'deepseek-v4.1-flash'),
    'apiopencc': ('apiopencc', 'gpt-6-astra'),
    'felixxxxx': ('felixxxxx', 'gpt-6-astra'),
}

# Model ids the Token Plan channel actually serves; those are kept as-is.
ALIYUN_MODELS = {
    'deepseek-v4.1-flash',
    'deepseek-v4-pro',
    'deepseek-v4-pro-0813',
    'deepseek-v4-flash-0731',
}


def model_for(provider, model):
    if provider in ('official', 'apiopencc', 'felixxxxx') and (model or '').startswith('gpt-'):
        return model
    if provider == 'deepseek' and model in ('deepseek-v4-pro', 'deepseek-v4-flash'):
        return model
    if provider == 'aliyun' and model in ALIYUN_MODELS:
        return model
    return TARGETS[provider][1]


def migrate(home, target, switch_config=True, now=None):
    provider, _ = TARGETS[target]
    home = Path(home).resolve()
    database = home / 'state_5.sqlite'
    script = home / 'skills/model-switch/scripts/codex-switch.sh'
    if not database.is_file():
        raise RuntimeError('未找到本机会话数据库')
    connection = sqlite3.connect(database, timeout=5)
    connection.row_factory = sqlite3.Row
    history = home / 'thread_history_1.sqlite'
    staged = []
    replaced = []
    config_backups = {}
    scratch = Path(tempfile.mkdtemp(prefix='quota-channel-', dir=home))
    config_changed = False
    cleanup = True
    try:
        if history.is_file():
            connection.execute('ATTACH DATABASE ? AS history', (str(history),))
        connection.execute('BEGIN IMMEDIATE')
        rows = connection.execute('''SELECT id, rollout_path, model, model_provider
            FROM threads WHERE archived = 0 AND updated_at >= ?
            AND source IN ('cli', 'vscode', 'exec', 'appServer')''',
            ((time.time() if now is None else now) - 7 * 86400,)).fetchall()
        for row in rows:
            path = Path(row['rollout_path']).resolve()
            if not path.is_relative_to(home / 'sessions') or not path.is_file():
                raise RuntimeError('会话文件不在本机 sessions 目录或已丢失：' + row['id'])
            model = model_for(target, row['model'])
            with path.open('rb') as source:
                old_line = source.readline()
                record = json.loads(old_line)
                if record.get('type') != 'session_meta' or record['payload'].get('id') != row['id']:
                    raise RuntimeError('会话元数据格式不兼容：' + row['id'])
                if (record['payload'].get('model_provider') == provider
                        and row['model_provider'] == provider and row['model'] == model):
                    continue
                record['payload']['model_provider'] = provider
                new_line = (json.dumps(record, ensure_ascii=False, separators=(',', ':')) + '\n').encode()
                staged_path = scratch / (row['id'] + '.new')
                with staged_path.open('wb') as output:
                    output.write(new_line)
                    shutil.copyfileobj(source, output, length=1024 * 1024)
                    output.flush()
                    os.fsync(output.fileno())
                shutil.copystat(path, staged_path)
            staged.append((row, path, staged_path, len(new_line) - len(old_line), model))

        # All records and history columns are validated before modifying anything.
        if history.is_file():
            connection.execute('SELECT rollout_byte_offset, rollout_end_byte_offset FROM history.thread_turns LIMIT 0')
            connection.execute('SELECT next_rollout_byte_offset FROM history.thread_history_projection_state LIMIT 0')
        if switch_config:
            for name in ('config.toml', 'auth.json'):
                path = home / name
                backup = scratch / name
                if path.exists():
                    shutil.copy2(path, backup)
                    config_backups[path] = backup
                else:
                    config_backups[path] = None
            config_changed = True
            result = subprocess.run(['/bin/bash', str(script), target],
                                    env=dict(os.environ, CODEX_HOME=str(home)),
                                    capture_output=True, text=True, timeout=60)
            if result.returncode:
                raise RuntimeError(result.stderr.strip() or '默认渠道切换失败')

        for row, path, staged_path, delta, model in staged:
            original = scratch / (row['id'] + '.original')
            # Keep the live path present until the atomic replacement succeeds.
            try:
                os.link(path, original)
            except OSError:
                shutil.copy2(path, original)
            replaced.append((path, original))
            os.replace(staged_path, path)
            connection.execute('UPDATE threads SET model_provider=?, model=? WHERE id=?',
                               (provider, model, row['id']))
            if row['model'] != model:
                connection.execute('UPDATE threads SET reasoning_effort=? WHERE id=?',
                                   ('high', row['id']))
            if history.is_file() and delta:
                # Preserve the projected history; only byte positions after the header move.
                connection.execute('''UPDATE history.thread_turns SET
                    rollout_byte_offset=CASE WHEN rollout_byte_offset>0 THEN rollout_byte_offset+? ELSE rollout_byte_offset END,
                    rollout_end_byte_offset=CASE WHEN rollout_end_byte_offset>0 THEN rollout_end_byte_offset+? ELSE rollout_end_byte_offset END
                    WHERE thread_id=?''', (delta, delta, row['id']))
                connection.execute('''UPDATE history.thread_history_projection_state
                    SET next_rollout_byte_offset=next_rollout_byte_offset+?
                    WHERE thread_id=? AND next_rollout_byte_offset>0''', (delta, row['id']))
        connection.commit()
        return {'eligible': len(rows), 'changed': len(staged), 'provider': provider}
    except BaseException:
        try:
            connection.rollback()
            for path, original in reversed(replaced):
                os.replace(original, path)
            if config_changed:
                for path, backup in config_backups.items():
                    if backup is None:
                        path.unlink(missing_ok=True)
                    else:
                        shutil.copy2(backup, path)
        except BaseException as error:
            cleanup = False
            raise RuntimeError('恢复失败，原件已保留在 ' + str(scratch)) from error
        raise
    finally:
        connection.close()
        if cleanup:
            shutil.rmtree(scratch)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('target', choices=TARGETS)
    args = parser.parse_args()
    home = Path(os.environ.get('CODEX_HOME', Path.home() / '.codex')).resolve()
    # The app quits first. CLI sessions and other app servers must also release their files.
    wait_for_database_release(home)
    print(json.dumps(migrate(home, args.target), ensure_ascii=False))


def wait_for_database_release(home, timeout=10):
    deadline = time.monotonic() + timeout
    while True:
        busy = False
        for name in ('state_5.sqlite', 'thread_history_1.sqlite'):
            path = home / name
            if path.exists():
                holders = subprocess.run(['/usr/sbin/lsof', '-t', str(path)],
                                         capture_output=True, text=True, timeout=5)
                if holders.returncode not in (0, 1) or holders.stderr.strip():
                    raise RuntimeError('无法安全检查会话数据库占用，已取消切换')
                busy = busy or bool(holders.stdout.strip())
        if not busy:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError('Codex 或终端会话仍占用数据库，请退出后重试')
        time.sleep(0.5)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
