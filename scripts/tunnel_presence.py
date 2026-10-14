#!/usr/bin/env python3
"""Verify the packaged tunnel with synthetic loopback endpoints and credentials."""
import pathlib,tempfile,subprocess,os,threading,http.server,json,datetime,time,urllib.request,shutil
import argparse
parser=argparse.ArgumentParser()
parser.add_argument('--app',type=pathlib.Path,required=True,help='Verified private Sideport.app with bundled runtime')
args=parser.parse_args()
app=args.app.resolve()
base=pathlib.Path(tempfile.mkdtemp(prefix='sideport-live-tunnel-',dir='/private/tmp'))
entered=threading.Event(); release=threading.Event(); delivered=threading.Event()
sent=threading.Event()
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def reply(self,body,status=200):
  data=json.dumps(body).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def do_GET(self):
  if self.server.kind=='control' and '/poll' in self.path:
   if not sent.is_set():
    sent.set();self.reply({'commands':[{'request_id':'fixture-request-1','shard_token':'fixture-shard','command_type':'jsonrpc','channel':'main','created_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'response_timeout':'15s','jsonrpc':{'jsonrpc':'2.0','id':1,'method':'ping'}}]})
   else:
    time.sleep(.1);self.reply({'commands':[]})
  else:self.reply({},404)
 def do_POST(self):
  data=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or b'{}')
  if self.server.kind=='control':
   delivered.set();self.reply({});return
  if data.get('method')=='ping':
   entered.set();release.wait(10);self.reply({'jsonrpc':'2.0','id':data.get('id'),'result':{}})
  else:self.reply({'jsonrpc':'2.0','id':data.get('id'),'error':{'code':-32601,'message':'Fixture uses legacy protocol'}})
servers=[];threads=[];proc=None
try:
 for kind in ['control','mcp']:
  server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);server.kind=kind
  thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start();servers.append(server);threads.append(thread)
 runtime=str(app/'Contents/Resources/Runtime/work/tunnel-client/tunnel-client')
 exe=str(app/'Contents/MacOS/Sideport')
 env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(pathlib.Path.home()),'TUNNEL_CLIENT_PROFILE_DIR':str(base),'SIDEPORT_SYNTHETIC_KEY':'synthetic-local-fixture-key'}
 args=[runtime,'run','--control-plane.base-url','http://127.0.0.1:'+str(servers[0].server_port),'--control-plane.tunnel-id','tunnel_'+'0'*32,'--control-plane.api-key','env:SIDEPORT_SYNTHETIC_KEY','--control-plane.poll-channel','main','--mcp.server-url','url=http://127.0.0.1:'+str(servers[1].server_port)+'/mcp,channel=main','--health.listen-addr','127.0.0.1:0','--health.url-file',str(base/'health.url'),'--log.level','warn','--log.format','json']
 with (base/'runtime.log').open('w') as log:
  proc=subprocess.Popen(args,env=env,stdout=log,stderr=log)
  if not entered.wait(15):
   raise AssertionError('Fixture request did not reach MCP: '+(base/'runtime.log').read_text()[-1500:])
  url=(base/'health.url').read_text().strip()
  def active():
   r=subprocess.run([exe,'--live-presence-check',url],capture_output=True,text=True,timeout=5)
   assert r.returncode==0,r.stderr
   return json.loads(r.stdout)['active_requests']
  assert active()>0,'Real dispatcher did not count the executing request'
  release.set();assert delivered.wait(5),'Response was not delivered to the fake control plane'
  deadline=time.monotonic()+3
  while active()!=0 and time.monotonic()<deadline:time.sleep(.05)
  assert active()==0,'Real dispatcher lingered after completion'
  print('PASS: packaged official tunnel observes an executing MCP request and clears to zero after completion; all endpoints and credentials synthetic')
finally:
 release.set()
 if proc and proc.poll() is None:
  proc.terminate()
  try:proc.wait(timeout=8)
  except subprocess.TimeoutExpired:proc.kill();proc.wait()
 for server in servers:server.shutdown();server.server_close()
 for thread in threads:thread.join(timeout=2)
 shutil.rmtree(base,ignore_errors=True)
