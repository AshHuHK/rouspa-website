import { chromium, expect } from '@playwright/test';
import { createServer } from 'vite';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const root=fileURLToPath(new URL('../',import.meta.url));
const server=await createServer({root,server:{host:'127.0.0.1',port:5184,strictPort:false}});
let browser;
try {
  await server.listen();
  const address=server.httpServer.address(),origin=`http://127.0.0.1:${address.port}`;
  browser=await chromium.launch({headless:true,...(process.env.SPA_BROWSER_EXECUTABLE?{executablePath:process.env.SPA_BROWSER_EXECUTABLE}:{})});
  const context=await browser.newContext();
  const external=[];
  await context.route('**/*',route=>{
    const url=new URL(route.request().url());
    if(url.hostname==='127.0.0.1')return route.continue();
    external.push(url.origin);return route.abort();
  });
  const page=await context.newPage();
  const program=(await readFile(new URL('./test-ui-recovery-browser.js',import.meta.url),'utf8')).replace('http://127.0.0.1:5184',origin);
  const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
  const result=await new AsyncFunction('page','expect',program)(page,expect);
  expect(external,'synthetic UI tests must not contact production or external services').toEqual([]);
  console.log(`Isolated browser recovery checks passed: ${result.checks}; production requests: 0`);
} finally {
  await browser?.close();await server.close();
}
