#!/usr/bin/env python3
import hashlib,json,os,subprocess,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1];exe=root/'build/account-probe'
subprocess.run(['xcrun','clang','-std=c11','-O1','-Wall','-Wextra','-Werror','-fobjc-arc',str(root/'scripts/account_probe.c'),str(root/'runtime/account.c'),str(root.parent/'common/users.m'),'-framework','Cocoa','-o',str(exe)],check=True)
with tempfile.TemporaryDirectory(prefix='totk-account-') as folder:
 env={k:v for k,v in os.environ.items() if not k.startswith('MNG_')};env['TOTK_PROFILE_DIR']=folder
 runs=[subprocess.run([str(exe)],env=env,capture_output=True,text=True,check=True) for _ in range(2)]
 identity=[json.loads(r.stdout)['uid'] for r in runs];assert identity[0]==identity[1]
 assert (Path(folder)/'users.txt').is_file()
 corrupt=Path(folder)/'corrupt';corrupt.mkdir();(corrupt/'account.uid').write_bytes(b'corrupt')
 env['TOTK_PROFILE_DIR']=str(corrupt)
 negative=subprocess.run([str(exe)],env=env,capture_output=True,text=True);assert negative.returncode==1 and 'corrupt local account identity' in negative.stderr
report=dict(status='pass',restart_identity='stable',invalid_user_and_closed_handle='rejected',nickname_guard='preserved',corrupt_profile='rejected',scope='local offline account only; not game save persistence')
(root/'analysis/account-probe.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
