import {mkdtemp,writeFile,mkdir,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {spawn,execFileSync} from 'node:child_process';
import {createServer} from 'node:net';
import assert from 'node:assert/strict';
const root=resolve(import.meta.dirname,'..');
const pkg=join(root,'skills/ios-local-publish/scripts/Publisher');
const scratch=join(tmpdir(),'ios-publish-protocol-build');
execFileSync('swift',['build','--package-path',pkg,'--scratch-path',scratch],{stdio:'pipe'});
const bin=execFileSync('swift',['build','--package-path',pkg,'--scratch-path',scratch,'--show-bin-path'],{encoding:'utf8'}).trim();
const reservation=createServer();await new Promise(r=>reservation.listen(0,'127.0.0.1',r));
const port=reservation.address().port;await new Promise(r=>reservation.close(r));
const state=await mkdtemp(join(tmpdir(),'publish-protocol-'));
await writeFile(join(state,'admin-token'),'test-admin-token',{mode:0o600});
await mkdir(join(state,'site'));await writeFile(join(state,'site','artifact.ipa'),'fixture IPA bytes');
const ipa=globalThis.process.argv[2];
const hardwareUDID=globalThis.process.env.IOS_PUBLISH_TEST_UDID ?? '00000000-0000000000000001';
const mount='/ios-publish-test-'+Date.now();
let publicBase='https://example.ts.net/ios-publish';
if(ipa){const status=JSON.parse(execFileSync('tailscale',['status','--json'],{encoding:'utf8'}));publicBase='https://'+status.Self.DNSName.replace(/\.$/,'')+':8443'+mount;}
const process=spawn(join(bin,'ios-publish'),['daemon','--no-bonjour','--state-dir',state,'--port',String(port),'--base-url',publicBase],{stdio:'pipe'});
let errors='';process.stderr.on('data',b=>errors+=b);
const base=`http://127.0.0.1:${port}`;
try {
 let ready=false;
 for(let i=0;i<80;i++){try{if((await fetch(base+'/healthz')).ok){ready=true;break}}catch{} await new Promise(r=>setTimeout(r,100));}
 assert.ok(ready,errors);
 const id='abcdef00-1234-5678-9000-012345678900',token='a'.repeat(64);
 const post=async(path,body,bearer=token)=>fetch(base+path,{method:'POST',headers:{Authorization:'Bearer '+bearer,'Content-Type':'application/json'},body:JSON.stringify(body)});
 assert.equal((await post('/api/connect',{id,name:'Test phone',platform:'iPhone'})).status,200);
 assert.deepEqual((await (await post('/api/heartbeat',{id})).json()).releases,[]);
 assert.equal((await post('/api/heartbeat',{id},'b'.repeat(64))).status,400);
 assert.equal((await post('/admin/receivers',{})).status,400);
 assert.equal((await post('/api/publish',{id})).status,404);
 const bind=await post('/admin/bind',{id,udid:hardwareUDID},'test-admin-token');assert.equal(bind.status,200);
 const list=await (await post('/admin/receivers',{},'test-admin-token')).json();assert.equal(list.receivers[0].connected,true);
 assert.equal(list.receivers[0].secret_hash,undefined);
 assert.equal((await post('/api/receipts',{id,release_ids:[]})).status,200);
 const app='com.example.catalog';
 assert.equal((await post('/api/apps/save',{id,bundle_id:app,name:'Temporary app'})).status,200);
 assert.equal((await post('/api/apps/save',{id,bundle_id:app,name:'Renamed app'})).status,200);
 let snapshot=await (await post('/api/heartbeat',{id})).json();
 assert.equal(snapshot.apps.find(a=>a.bundle_id===app).name,'Renamed app');
 assert.equal((await post('/api/apps/delete',{id,bundle_id:app})).status,200);
 snapshot=await (await post('/api/heartbeat',{id})).json();
 assert.ok(!snapshot.apps.some(a=>a.bundle_id===app));
 if(ipa){
  execFileSync('tailscale',['serve','--bg','--yes','--https=8443','--set-path='+mount,'http://127.0.0.1:'+port],{stdio:'pipe'});
  const publication=await post('/admin/publish',{id,ipa_path:resolve(ipa),min_validity_days:30},'test-admin-token');
  const release=await publication.json();assert.equal(publication.status,200,JSON.stringify(release));
  assert.equal(release.hosting_verified,true);assert.equal(release.delivery.received,false);assert.ok(release.install_url.startsWith("itms-services://?"));
  const inbox=await (await post('/api/heartbeat',{id})).json();assert.equal(inbox.releases[0].release_id,release.release_id);
  await post('/api/receipts',{id,release_ids:[release.release_id]});
  const receipt=await (await post('/admin/receipt',{id,release_id:release.release_id},'test-admin-token')).json();assert.equal(receipt.received,true);assert.equal(receipt.installed,false);
  console.log('Real signed IPA passed signature/profile validation, trusted HTTPS manifest/full-IPA verification, inbox delivery and receipt (isolated test receiver).');
  assert.equal((await post('/api/builds/delete',{id,release_id:release.release_id})).status,200);
  assert.equal((await (await post('/api/heartbeat',{id})).json()).releases.length,0);
  const lower=await post('/admin/check-version',{bundle_id:release.bundle_id,version:'0.0.0',build:'1'},'test-admin-token');
  assert.equal(lower.status,400,'Deleting a build must not reset its version floor');
  assert.equal((await fetch(release.ipa_url)).ok,false);
 }
 const head=await fetch(base+'/artifact.ipa',{method:'HEAD'});assert.equal(head.headers.get('content-length'),'17');
 assert.equal(await (await fetch(base+'/artifact.ipa')).text(),'fixture IPA bytes');
 await post('/api/heartbeat',{id,active:false});
 const off=await (await post('/admin/receivers',{},'test-admin-token')).json();assert.equal(off.receivers[0].connected,false);
 console.log('Swift daemon HTTP protocol passed: enrollment, isolation, admin authorization, binding, presence, receipts, GET/HEAD');
} finally {if(ipa)execFileSync('tailscale',['serve','--https=8443','--set-path='+mount,'off'],{stdio:'pipe'});process.kill('SIGTERM');await new Promise(r=>process.once('exit',r));await rm(state,{recursive:true,force:true});}
