"""Optional local integration check with Codex; no turn or external API call."""
import json, os, pathlib, queue, subprocess, tempfile, threading, time

with tempfile.TemporaryDirectory(prefix='quota-resume-probe-') as directory:
    home = pathlib.Path(directory)
    env = dict(os.environ, CODEX_HOME=directory)
    process = subprocess.Popen(['codex', 'app-server', '--stdio'], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
    messages = queue.Queue()
    def read():
        for line in process.stdout:
            messages.put(json.loads(line))
    threading.Thread(target=read, daemon=True).start()
    def call(method, params):
        request_id = time.time_ns()
        process.stdin.write(json.dumps(dict(id=request_id, method=method, params=params))+'\n')
        process.stdin.flush()
        while True:
            message = messages.get(timeout=40)
            if message.get('id') == request_id:
                if 'error' in message: raise RuntimeError(message['error'])
                return message['result']
    try:
        call('initialize', {'clientInfo':{'name':'quota_probe','version':'1'}, 'capabilities':{'experimentalApi':True}})
        import uuid, datetime
        thread_id = str(uuid.uuid4())
        stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
        path = home/'sessions'/'2026'/'09'/'14'/('rollout-'+thread_id+'.jsonl')
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({'timestamp':stamp,'type':'session_meta','payload':{
            'id':thread_id,'timestamp':stamp,'cwd':directory,'originator':'codex_cli_rs',
            'cli_version':'0.153.4','source':'cli','model_provider':'openai',
            'base_instructions':{'text':'Test fixture'}}})+'\n')
        with path.open('a') as output:
            output.write(json.dumps({'timestamp':stamp,'type':'turn_context','payload':{'cwd':directory,'approval_policy':'never','sandbox_policy':{'type':'read-only'},'model':'gpt-5.6-sol','effort':'high'}})+'\n')
        import sqlite3, importlib.util
        db = sqlite3.connect(home/'state_5.sqlite')
        db.execute('INSERT INTO threads (id,rollout_path,created_at,updated_at,source,model_provider,cwd,title,sandbox_policy,approval_mode,model) VALUES (?,?,?,?,?,?,?,?,?,?,?)', (thread_id,str(path),int(time.time()),int(time.time()),'cli','openai',directory,'fixture','read-only','never','gpt-5.6-sol'))
        db.commit()
        db.close()
        spec = importlib.util.spec_from_file_location('migration', pathlib.Path(__file__).with_name('switch-recent.py'))
        migration = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(migration)
        assert migration.migrate(home,'aliyun',False)['changed'] == 1
        result = call('thread/resume', {'threadId':thread_id,
            'config':{'model_provider':'aliyun','model':'deepseek-v4-pro-0813','model_providers.aliyun':{'name':'fixture','base_url':'http://127.0.0.1:1/v1','wire_api':'responses'}},'excludeTurns':True})
        assert result.get('modelProvider') == 'aliyun', result.get('modelProvider')
        assert result.get('model') == 'deepseek-v4-pro-0813', result.get('model')
        call('thread/unsubscribe', {'threadId':thread_id})
        import sqlite3
        db = sqlite3.connect(home/'state_5.sqlite')
        assert db.execute('select model_provider,model from threads where id=?',(thread_id,)).fetchone() == ('aliyun','deepseek-v4-pro-0813')
        db.close()
        with path.open() as source:
            assert json.loads(source.readline())['payload']['model_provider'] == 'aliyun'
            assert json.loads(source.readline())['payload']['model'] == 'gpt-5.6-sol'
        print('PASS: native resume uses migrated provider/model; original turn context preserved')
    finally:
        process.terminate()
        process.wait(timeout=10)
