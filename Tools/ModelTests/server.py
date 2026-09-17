from http.server import BaseHTTPRequestHandler,HTTPServer
import json
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def answer(self,status,body):
  self.send_response(status);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(json.dumps(body).encode())
 def do_GET(self):self.answer(200,{'data':[{'id':'good'},{'id':'good'}]})
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  mode=body['model']
  if mode=='redirect':
   self.send_response(302);self.send_header('Location','http://127.0.0.1:18091/redirected');self.end_headers();return
  if mode=='unauthorized':self.answer(401,{});return
  if mode=='http200error':self.answer(200,{'error':{'message':'failure test-secret'}});return
  self.answer(200,{'choices':[{'finish_reason':'length' if mode=='truncated' else 'stop','message':{'content':'' if mode=='empty' else '测试'}}]})
HTTPServer(('127.0.0.1',18091),Handler).serve_forever()
