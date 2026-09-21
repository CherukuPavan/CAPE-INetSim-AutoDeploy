#!/usr/bin/env python3
import argparse,random,socket,struct,sys
p=argparse.ArgumentParser()
p.add_argument('server')
p.add_argument('expected')
p.add_argument('--name',default='cape-inetsim-validation.invalid')
p.add_argument('--timeout',type=float,default=3.0)
a=p.parse_args()
qid=random.randint(0,65535)
labels=a.name.rstrip('.').split('.')
qname=b''.join(bytes([len(x)])+x.encode('ascii') for x in labels)+b'\0'
pkt=struct.pack('!HHHHHH',qid,0x0100,1,0,0,0)+qname+struct.pack('!HH',1,1)
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.settimeout(a.timeout)
s.sendto(pkt,(a.server,53))
data,_=s.recvfrom(4096)
if len(data)<12: raise SystemExit('short DNS reply')
rid,flags,qd,an,ns,ar=struct.unpack('!HHHHHH',data[:12])
if rid!=qid or not(flags & 0x8000) or an<1: raise SystemExit('invalid DNS reply')
o=12
for _ in range(qd):
    while data[o]!=0:
        if data[o]&0xC0==0xC0:
            o+=2
            break
        o += 1+data[o]
    else:
        o+=1
    o+=4
answers=[]
for _ in range(an):
    if data[o]&0xC0==0xC0:
        o+=2
    else:
        while data[o]!=0: o += 1+data[o]
        o+=1
    typ,cls,ttl,rdlen=struct.unpack('!HHIH',data[o:o+10])
    o+=10
    rdata=data[o:o+rdlen]
    o+=rdlen
    if typ==1 and cls==1 and rdlen==4: answers.append(socket.inet_ntoa(rdata))
if a.expected not in answers:
    print('answers='+','.join(answers),file=sys.stderr)
    raise SystemExit(1)
print(a.expected)
