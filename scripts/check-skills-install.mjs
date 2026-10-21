import {mkdtemp, readFile, readdir, rm, mkdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';
const root=resolve(import.meta.dirname,'..');
const source=join(root,'skills/ios-local-publish');
async function compare(from,to) {
  for (const entry of await readdir(from,{withFileTypes:true})) {
    if (entry.name.startsWith('.')) continue;
    const a=join(from,entry.name),b=join(to,entry.name);
    if(entry.isDirectory()) await compare(a,b);
    else assert.deepEqual(await readFile(a),await readFile(b),b);
  }
}
for(const copy of [false,true]) {
  const temp=await mkdtemp(join(tmpdir(),'publish-skill-'));
  try {
    execFileSync('npx',['--yes','skills@1.7.2','add',root,'--skill','ios-local-publish','--agent','codex','claude-code','--yes',...(copy?['--copy']:[])],{cwd:temp,env:{...process.env,DISABLE_TELEMETRY:'1'},stdio:'pipe'});
    const installed=join(temp,'.agents/skills/ios-local-publish');
    await compare(source,installed);
    const output=execFileSync(join(installed,'scripts/ios-local-publish'),['--help'],{cwd:temp,encoding:'utf8'});
    assert.match(output,/native iOS build inbox/);
    console.log(`${copy?'Copy':'Symlink'} install: files match and Swift launcher works outside checkout`);
  } finally {await rm(temp,{recursive:true,force:true});}
}
