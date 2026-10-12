// Fresh gateway trust is established only for the exact tool definitions shipped with Sideport.
import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const dir=path.dirname(fileURLToPath(import.meta.url));
const canonical=value=>JSON.stringify(value,(_key,item)=>item&&typeof item==='object'&&!Array.isArray(item)?Object.fromEntries(Object.entries(item).sort(([a],[b])=>a.localeCompare(b))):item);
export async function reviewBundle(config, endpoint = 'http://127.0.0.1:18089') {
 const expected=JSON.parse(await fs.readFile(dir+'/bundled-tools.json','utf8'));
 const api=async(method,route,body)=>{
  const response=await fetch(endpoint+route,{method,headers:{'X-API-Key':config.api_key,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(5000)});
  if(!response.ok)throw new Error('Bundled tool verification failed ('+response.status+')');return response.json();
 };
 let tools;
 for(let i=0;i<30;i++) {
  tools=(await api('GET','/api/v1/servers/permissions/tools')).data?.tools;
  if(tools?.length===expected.length)break;
  await new Promise(resolve=>setTimeout(resolve,500));
 }
 if(!tools || tools.length!==expected.length || expected.some(e=>!tools.some(t=>t.name===e.name&&t.description===e.description&&canonical(t.schema)===canonical(e.inputSchema))))throw new Error('Gateway tools differ from the definitions bundled with Sideport. Connection remains off.');
 await api('POST','/api/v1/servers/permissions/tools/approve',{tools:expected.map(t=>t.name)});
}
