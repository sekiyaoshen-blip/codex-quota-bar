import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('migration', Path(__file__).with_name('switch-recent.py'))
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / 'sessions').mkdir()
        self.db = sqlite3.connect(self.home / 'state_5.sqlite')
        self.addCleanup(self.db.close)
        self.db.execute('CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, model TEXT, model_provider TEXT, archived INT, updated_at INT, source TEXT, reasoning_effort TEXT)')
        self.hist = sqlite3.connect(self.home / 'thread_history_1.sqlite')
        self.addCleanup(self.hist.close)
        self.hist.execute('CREATE TABLE thread_turns (thread_id TEXT, rollout_byte_offset INT, rollout_end_byte_offset INT)')
        self.hist.execute('CREATE TABLE thread_history_projection_state (thread_id TEXT, next_rollout_byte_offset INT)')
        self.now = 2_000_000
        self.originals = {}

    def add(self, name, age=0, archived=0, source='vscode', model='gpt-5.6-sol'):
        path = self.home / 'sessions' / (name + '.jsonl')
        header = json.dumps({'type':'session_meta','payload':{'id':name,'model_provider':'openai','base_instructions':{'text':'保持中文和历史'}}}).encode() + b'\n'
        body = b'{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}\n'
        path.write_bytes(header + body)
        self.originals[name] = path.read_bytes()
        self.db.execute('INSERT INTO threads VALUES (?,?,?,?,?,?,?,?)', (name,str(path),model,'openai',archived,self.now-age,source,'ultra'))
        self.db.commit()
        self.hist.execute('INSERT INTO thread_turns VALUES (?,?,?)', (name,len(header),len(header+body)))
        self.hist.execute('INSERT INTO thread_history_projection_state VALUES (?,?)', (name,len(header+body)))
        self.hist.commit()
        return path

    def test_selection_history_offsets_and_idempotence(self):
        path = self.add('recent')
        self.add('old', age=604801)
        self.add('archived', archived=1)
        self.add('agent', source='{"subagent":{}}')
        result = migration.migrate(self.home, 'felixxxxx', False, self.now)
        self.assertEqual(result['changed'], 1)
        header, body = path.read_bytes().split(b'\n',1)
        self.assertEqual(json.loads(header)['payload']['model_provider'],'felixxxxx')
        self.assertEqual(body, self.originals['recent'].split(b'\n',1)[1])
        self.assertEqual(self.db.execute('SELECT model FROM threads WHERE id="recent"').fetchone()[0],'gpt-5.6-sol')
        offset, end = self.hist.execute('SELECT rollout_byte_offset,rollout_end_byte_offset FROM thread_turns WHERE thread_id="recent"').fetchone()
        self.assertEqual(path.read_bytes()[offset:end], body)
        self.assertEqual(self.hist.execute('SELECT next_rollout_byte_offset FROM thread_history_projection_state WHERE thread_id="recent"').fetchone()[0],len(path.read_bytes()))
        for name in ('old','archived','agent'):
            self.assertEqual((self.home/'sessions'/(name+'.jsonl')).read_bytes(), self.originals[name])
        self.assertEqual(migration.migrate(self.home,'felixxxxx',False,self.now)['changed'],0)

    def test_failed_replace_restores_all_records(self):
        first = self.add('first')
        second = self.add('second')
        replace = migration.os.replace
        def fail(source, destination):
            if str(source).endswith('second.new'):
                raise OSError('injected write failure')
            return replace(source,destination)
        with patch.object(migration.os,'replace',side_effect=fail):
            with self.assertRaises(OSError): migration.migrate(self.home,'felixxxxx',False,self.now)
        self.assertEqual(first.read_bytes(),self.originals['first'])
        self.assertEqual(second.read_bytes(),self.originals['second'])
        self.assertEqual(self.db.execute('SELECT DISTINCT model_provider FROM threads').fetchall(),[('openai',)])

    def test_cross_family_model(self):
        self.assertEqual(migration.model_for('aliyun','gpt-6-astra'),'deepseek-v4-pro-0813')
        self.assertEqual(migration.model_for('official','deepseek-v4-pro'),'gpt-6-astra')
        self.add('cross')
        migration.migrate(self.home,'aliyun',False,self.now)
        self.assertEqual(self.db.execute('SELECT model,reasoning_effort FROM threads').fetchone(),('deepseek-v4-pro-0813','high'))

    def test_config_failure_restores_login_and_history(self):
        path = self.add('recent')
        config = self.home/'config.toml'
        auth = self.home/'auth.json'
        config.write_text('original')
        auth.write_text('login fixture')
        def fail(*args, **kwargs):
            config.write_text('changed')
            auth.write_text('changed')
            return subprocess.CompletedProcess(args,1,'','injected config failure')
        with patch.object(migration.subprocess,'run',side_effect=fail):
            with self.assertRaises(RuntimeError):
                migration.migrate(self.home,'felixxxxx',True,self.now)
        self.assertEqual(config.read_text(),'original')
        self.assertEqual(auth.read_text(),'login fixture')
        self.assertEqual(path.read_bytes(),self.originals['recent'])

    def test_invalid_record_cancels_before_switch(self):
        self.add('recent').write_text('{"type":"unknown"}\n')
        with patch.object(migration.subprocess,'run') as run:
            with self.assertRaises(RuntimeError):
                migration.migrate(self.home,'felixxxxx',True,self.now)
            run.assert_not_called()

    def test_busy_or_uncheckable_database_is_rejected(self):
        for result in (subprocess.CompletedProcess([],0,'123\n',''),
                       subprocess.CompletedProcess([],2,'','error')):
            with patch.object(migration.subprocess,'run',return_value=result):
                with self.assertRaises(RuntimeError):
                    migration.wait_for_database_release(self.home,timeout=0)


if __name__ == '__main__': unittest.main()
