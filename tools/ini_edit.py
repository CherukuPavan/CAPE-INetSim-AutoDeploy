#!/usr/bin/env python3
import argparse,re,sys

p=argparse.ArgumentParser()
p.add_argument('path'); p.add_argument('section'); p.add_argument('key'); p.add_argument('value')
a=p.parse_args()
lines=open(a.path,encoding='utf-8').read().splitlines(True)
sec_re=re.compile(r'^\s*\[([^]]+)\]\s*(?:[#;].*)?$')
key_re=re.compile(r'^(\s*)'+re.escape(a.key)+r'\s*=.*$',re.I)
start=None; end=len(lines)
for i,line in enumerate(lines):
    m=sec_re.match(line.rstrip('\r\n'))
    if not m: continue
    if start is None and m.group(1).strip().lower()==a.section.lower():
        start=i+1; continue
    if start is not None:
        end=i; break
if start is None:
    print(f'missing section [{a.section}]',file=sys.stderr); sys.exit(2)
for i in range(start,end):
    m=key_re.match(lines[i].rstrip('\r\n'))
    if m:
        nl='\r\n' if lines[i].endswith('\r\n') else '\n'
        lines[i]=f'{m.group(1)}{a.key} = {a.value}{nl}'
        break
else:
    nl='\n'
    insert=end
    if insert>start and not lines[insert-1].endswith(('\n','\r')): lines[insert-1]+='\n'
    lines.insert(insert,f'{a.key} = {a.value}{nl}')
open(a.path,'w',encoding='utf-8',newline='').writelines(lines)
