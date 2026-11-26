import http.server,json,os,re,secrets,subprocess,sys,tempfile,threading,time
from pathlib import Path
sys.path.insert(0,str(Path.cwd()/'scripts'))
from webdriver_check import Raw
from safari_reference import free_port,wait_for_port
root=Path(tempfile.mkdtemp(prefix='lumen-local-web-identity-'))

route='/'+secrets.token_urlsafe(28)
app=Path(os.environ['LUMEN_TEST_APP']).resolve()/'Contents/MacOS/Lumen'
page=b'''<!doctype html><meta charset="utf-8"><title>Lumen: local browser comparison</title><h1>Local browser comparison</h1><p>This page only checks basic browser settings on this Mac.</p><script>
const d={ua:navigator.userAgent,platform:navigator.platform,vendor:navigator.vendor,language:navigator.language,languages:Array.from(navigator.languages),cookies:navigator.cookieEnabled,dark:matchMedia("(prefers-color-scheme: dark)").matches,reducedMotion:matchMedia("(prefers-reduced-motion: reduce)").matches};
document.documentElement.dataset.result=JSON.stringify(d);
fetch(location.pathname+"/result",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(d)}).catch(()=>{});
</script>'''
data={};who='';arrived=threading.Event()
class Page(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def allowed(self):return self.headers.get('Host')==f'127.0.0.1:{server.server_port}'
 def do_GET(self):
  if not self.allowed() or self.path!=route:self.send_error(404);return
  data[who]={'httpUA':self.headers.get('User-Agent'),'httpLanguage':self.headers.get('Accept-Language')}
  self.send_response(200);self.send_header('Cache-Control','no-store');self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(page)));self.end_headers();self.wfile.write(page)
 def do_POST(self):
  if not self.allowed() or self.path!=route+'/result' or self.headers.get('Origin')!=origin or who not in data:self.send_error(404);return
  n=int(self.headers.get('Content-Length',0))
  if not (1<=n<=4096):self.send_error(400);return
  data[who]['page']=json.loads(self.rfile.read(n));self.send_response(204);self.end_headers();arrived.set()
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Page)
origin=f'http://127.0.0.1:{server.server_port}'; url=origin+route
threading.Thread(target=server.serve_forever,daemon=True).start()
def stop(p):
 if not p or p.poll() is not None:return
 p.terminate()
 try:p.wait(timeout=8)
 except subprocess.TimeoutExpired:p.kill();p.wait()
def summarize(x):
 def browser(s):
  v=re.search(r'Version/([\d.]+)',s or '')
  return ('Safari '+v.group(1) if v and 'Safari/' in s else 'other')
 d=x['page']
 return {'httpBrowser':browser(x['httpUA']),'jsBrowser':browser(d['ua']),'sameUAWithinBrowser':d['ua']==x['httpUA'],'platform':d['platform'],'vendor':d['vendor'],'httpPreferredLanguage':(x['httpLanguage'] or '').split(',')[0].partition(';')[0],'jsPreferredLanguage':d['language'],'languageList':d['languages'],'cookies':d['cookies'],'dark':d['dark'],'reducedMotion':d['reducedMotion']}
try:
 with (root/'drivers.log').open('w') as err:
  for who in ('Safari','Lumen'):
   arrived.clear();client=None;service=None;proxy=None
   try:
    if who=='Safari':
     subprocess.run(['/usr/bin/open','-g','-b','com.apple.Safari',url],check=True)
    else:
     port=free_port()
     proxy=subprocess.Popen([sys.executable,'scripts/selftest_proxy.py','--http',str(port),'--socks',str(free_port())],stdout=err,stderr=err)
     wait_for_port(port,8)
     with (root/'lumen.log').open('w') as runlog:
      service=subprocess.Popen([str(app),'--webdriver-serve'],env=dict(os.environ,PB_SELFTEST_HTTP_PROXY_PORT=str(port),PRIVACYBROWSER_VAULT_DIR=str(root/'own-vault')),stdout=runlog,stderr=err)
     address=None
     for _ in range(180):
      address=next((l.removeprefix('WEBDRIVER ADDRESS ') for l in (root/'lumen.log').read_text().splitlines() if l.startswith('WEBDRIVER ADDRESS ')),None)
      if address:break
      if service.poll() is not None:raise RuntimeError('Lumen exited early')
      time.sleep(.25)
     if not address:raise RuntimeError('Lumen fixture did not start')
     client=Raw(address);client.get(url)
    if not arrived.wait(20):raise RuntimeError(who+' did not return page measurement')
    print(who,json.dumps(summarize(data[who]),ensure_ascii=False),flush=True)
   finally:
    if client:
     try:client.quit()
     except Exception:pass
    stop(service);stop(proxy)
 Path(os.environ['QA_RESULT']).write_text(json.dumps({k:summarize(v) for k,v in data.items()},ensure_ascii=False,indent=2))
 print('Same full HTTP UA across both:',data['Lumen']['httpUA']==data['Safari']['httpUA'])
 print('Same full JS UA across both:',data['Lumen']['page']['ua']==data['Safari']['page']['ua'])
 print('Same complete Accept-Language across both:',data['Lumen']['httpLanguage']==data['Safari']['httpLanguage'])
 if not any("Safari's window" in line for line in (root/'lumen.log').read_text().splitlines() if line.startswith('WEBDRIVER INFO')): raise RuntimeError('Lumen did not confirm a Safari-hosted window')
 print('Lumen confirmed a Safari-hosted window')
finally:server.shutdown()
