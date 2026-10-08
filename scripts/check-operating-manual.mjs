import {readFile,readdir,writeFile,stat} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const root=new URL('../',import.meta.url);
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const paths=[];
async function collect(directory,pattern) {
 for(const entry of await readdir(new URL(directory,root),{withFileTypes:true})) {
  const path=directory+entry.name;
  if(entry.isDirectory())await collect(path+'/',pattern);
  else if(pattern.test(entry.name))paths.push(path);
 }
}
await collect('src/',/\.(js|jsx)$/);await collect('supabase/migrations/',/\.sql$/);await collect('supabase/functions/',/\.ts$/);await collect('server/',/\.mjs$/);await collect('api/',/\.js$/);
const manual=await readFile(new URL('ROU_SPA_OPERATING_MANUAL.md',root),'utf8');
assert(manual.length>30000,'Full manual is required for the steward.');
for(const heading of ['預約','排班','打卡','薪資','POS','重設','問管家','權限'])assert(manual.includes(heading),'Missing operating domain: '+heading);
assert(!/sk-kimi-[A-Za-z0-9_-]+|ghp_[A-Za-z0-9]+|sb_secret_[A-Za-z0-9_-]+/.test(manual),'Manual cannot contain credentials.');
for(const target of [...manual.matchAll(/\]\(([^)]+)\)/g)].map(m=>m[1])) {
 if(/^(https?:|#|mailto:)/.test(target))continue;
 assert(!target.startsWith('/') && !target.includes('..'),'Manual links must be repository-local: '+target);
 await stat(new URL(target.split('#')[0],root));
}
const sources={};for(const path of paths.sort())sources[path]=sha(await readFile(new URL(path,root)));
const current={manual_sha256:sha(manual),sources};
const manifestUrl=new URL('docs/manual-sources.json',root);
if(process.argv.includes('--record')) {
 await writeFile(manifestUrl,JSON.stringify({reviewed_at:new Date().toISOString(),...current},null,2)+'\n');
 console.log('Recorded reviewed manual and '+paths.length+' rule sources.');
}else {
 const recorded=JSON.parse(await readFile(manifestUrl,'utf8'));
 assert.equal(recorded.manual_sha256,current.manual_sha256,'Manual changed: review it and record source fingerprints.');
 const changed=[...new Set([...Object.keys(recorded.sources),...Object.keys(sources)])].filter(path=>recorded.sources[path]!==sources[path]);
 assert.equal(changed.length,0,'Operating sources changed; update/review ROU_SPA_OPERATING_MANUAL.md, then run node scripts/check-operating-manual.mjs --record. Files: '+changed.join(', '));
 console.log('PASS: operating manual, local links, no credentials and '+paths.length+' reviewed rule sources.');
}
