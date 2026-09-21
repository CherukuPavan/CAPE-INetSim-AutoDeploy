#!/usr/bin/env python3
import argparse,ipaddress,json,secrets,socket,threading,time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs,urlparse

p=argparse.ArgumentParser()
p.add_argument("--bind",required=True)
p.add_argument("--client",required=True)
p.add_argument("--port",type=int,default=0)
p.add_argument("--token",required=True)
p.add_argument("--script",required=True)
p.add_argument("--result",required=True)
p.add_argument("--ready",required=True)
p.add_argument("--timeout",type=int,default=900)
a=p.parse_args()
allowed_client=str(ipaddress.ip_address(a.client))

script=Path(a.script).read_bytes()
result_path=Path(a.result)
ready_path=Path(a.ready)
done=threading.Event()

class Handler(BaseHTTPRequestHandler):
    server_version="CAPE-INetSim-AutoDeploy"
    def log_message(self,fmt,*args):
        return

    def authorized(self):
        try:
            peer=str(ipaddress.ip_address(self.client_address[0]))
        except ValueError:
            return False
        if peer != allowed_client:
            return False
        q=parse_qs(urlparse(self.path).query)
        return secrets.compare_digest((q.get("token") or [""])[0],a.token)

    def do_GET(self):
        u=urlparse(self.path)
        if u.path!="/script" or not self.authorized():
            self.send_error(404); return
        self.send_response(200)
        self.send_header("Content-Type","text/plain; charset=utf-8")
        self.send_header("Content-Length",str(len(script)))
        self.end_headers()
        self.wfile.write(script)

    def do_POST(self):
        u=urlparse(self.path)
        if u.path!="/result" or not self.authorized():
            self.send_error(404); return
        try:
            n=int(self.headers.get("Content-Length","0"))
        except ValueError:
            self.send_error(400); return
        if n<=0 or n>1024*1024:
            self.send_error(413); return
        body=self.rfile.read(n)
        try:
            doc=json.loads(body.decode("utf-8-sig"))
        except Exception:
            self.send_error(400); return
        tmp=result_path.with_suffix(result_path.suffix+".tmp")
        tmp.parent.mkdir(parents=True,exist_ok=True)
        tmp.write_text(json.dumps(doc,indent=2)+"\n")
        tmp.chmod(0o600)
        tmp.replace(result_path)
        self.send_response(204)
        self.end_headers()
        done.set()

server=ThreadingHTTPServer((a.bind,a.port),Handler)
server.timeout=1
ready_path.parent.mkdir(parents=True,exist_ok=True)
tmp=ready_path.with_suffix(ready_path.suffix+".tmp")
tmp.write_text(str(server.server_address[1])+"\n")
tmp.chmod(0o600)
tmp.replace(ready_path)

deadline=time.monotonic()+a.timeout
while not done.is_set() and time.monotonic()<deadline:
    server.handle_request()
server.server_close()
raise SystemExit(0 if done.is_set() else 124)
