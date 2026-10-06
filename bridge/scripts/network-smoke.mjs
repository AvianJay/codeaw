// Exercise the actual packaged runtime, with an isolated config and no agent.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { gunzipSync } from 'node:zlib';
import WebSocket from 'ws';
import { requestControl } from '../dist/desktop/control.js';

const executable=path.resolve(process.argv[2] ?? 'dist/bin/codeaw-bridge');
const home=fs.mkdtempSync(path.join(os.tmpdir(),'codeaw-network-smoke-'));
const file=path.join(home,'config.yaml'),fixture=path.join(home,'history.txt');
const text='Packaged network 中文 output abcdef\n'.repeat(10_000);
fs.writeFileSync(file,JSON.stringify({listen:{hosts:['127.0.0.1'],port:0},agents:{},workspaces:[home]}));
fs.writeFileSync(fixture,text);
const child=spawn(executable,['start','--headless','--config',file],{windowsHide:true,stdio:['ignore','pipe','pipe']});
let exited=false;
child.once('exit',()=>{exited=true;});
child.stdout.resume();child.stderr.resume();
const clients=[];
async function status(){
 const deadline=Date.now()+20_000;
 while(Date.now()<deadline){
  if(exited)throw new Error('Packaged network test bridge exited before startup');
  try{return await requestControl(file,{command:'status'},1000);}catch{}
  await new Promise(r=>setTimeout(r,100));
 }
 throw new Error('Packaged network test bridge failed to start');
}
try{
 const state=await status();
 const pair=await requestControl(file,{command:'pair'});
 const response=await fetch(`http://127.0.0.1:${state.port}/api/pair`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({code:pair.code,deviceName:'Packaged compression test'})});
 assert.equal(response.status,200);const {token}=await response.json();
 async function connect(gzip){
  const ws=new WebSocket(`ws://127.0.0.1:${state.port}/acp${gzip?'?codeawCompression=gzip':''}`,{headers:{Authorization:`Bearer ${token}`},perMessageDeflate:false});
  clients.push(ws);
  const pending=new Map();let next=0,zipped=0;
  ws.on('message',(data,binary)=>{
   const isGzip=binary&&data[0]===0x1f&&data[1]===0x8b;
   if(isGzip)zipped++;
   const message=JSON.parse((isGzip?gunzipSync(data):data).toString('utf8'));
   const done=pending.get(message.id);
   if(done){pending.delete(message.id);clearTimeout(done.timer);message.error?done.reject(new Error(message.error.message)):done.resolve(message.result);}
  });
  await once(ws,'open');
  const request=(method,params={})=>new Promise((resolve,reject)=>{
   const id=++next;
   const timer=setTimeout(()=>{pending.delete(id);reject(new Error('Packaged transport response timeout'));},15_000);
   pending.set(id,{resolve,reject,timer});ws.send(JSON.stringify({jsonrpc:'2.0',id,method,params}));
  });
  await request('initialize',{protocolVersion:1,clientCapabilities:{}});
  const start=ws._socket.bytesRead;
  const result=await request('_codeaw/fs/read',{path:fixture,maxBytes:1024*1024});
  assert.equal(result.text,text);
  return {wireBytes:ws._socket.bytesRead-start,gzipFrames:zipped};
 }
 const plain=await connect(false),compressed=await connect(true);
 assert.equal(plain.gzipFrames,0);assert.ok(compressed.gzipFrames>0);
 assert.ok(compressed.wireBytes<plain.wireBytes/20);
 console.log(JSON.stringify({packagedCompression:'passed',plain,compressed,noAgent:true,utf8Exact:true}));
}finally{
 clients.forEach(ws=>ws.terminate());
 await requestControl(file,{command:'stop'}).catch(()=>{});
 const deadline=Date.now()+20_000;
 while(!exited&&Date.now()<deadline)await new Promise(r=>setTimeout(r,50));
 if(!exited){child.kill();throw new Error('Isolated packaged bridge did not stop');}
 fs.rmSync(home,{recursive:true,force:true,maxRetries:5,retryDelay:100});
}
