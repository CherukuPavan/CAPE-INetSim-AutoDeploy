#!/usr/bin/env python3
import argparse
from pathlib import Path
import re

p=argparse.ArgumentParser(description="Best-effort credential redaction for AutoDeploy inventory bundles")
p.add_argument("root")
a=p.parse_args()
root=Path(a.root)

uri_credentials=re.compile(r'([A-Za-z][A-Za-z0-9+.-]*://)[^/@\s]+@')
authorization=re.compile(r'(?i)(\bauthorization\s*[:=]\s*)(?:bearer|basic)\s+[^\s\r\n]+')
kv_secret=re.compile(
    r'(?i)(\b(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|proxy[_-]?password)\b\s*[:=]\s*)'
    r'(?:"[^"\r\n]*"|\'[^\'\r\n]*\'|[^\s,;\]\}\r\n]+)'
)
cli_secret=re.compile(
    r'(?i)((?:--|\b)(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret)(?:=|\s+))'
    r'[^\s\r\n]+'
)
github_token=re.compile(r'\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b')
aws_access=re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b')
private_key_block=re.compile(
    r'-----BEGIN ([A-Z0-9 ]*PRIVATE KEY)-----.*?-----END \1-----',
    re.S,
)

def redact(text):
    text=private_key_block.sub(lambda m: f"-----BEGIN {m.group(1)}-----\n***REDACTED***\n-----END {m.group(1)}-----",text)
    text=uri_credentials.sub(r'\1***REDACTED***@',text)
    text=authorization.sub(r'\1***REDACTED***',text)
    text=kv_secret.sub(r'\1***REDACTED***',text)
    text=cli_secret.sub(r'\1***REDACTED***',text)
    text=github_token.sub('***REDACTED_GITHUB_TOKEN***',text)
    text=aws_access.sub('***REDACTED_ACCESS_KEY***',text)
    return text

changed=0
for path in root.rglob("*"):
    if not path.is_file() or path.is_symlink():
        continue
    try:
        data=path.read_bytes()
    except OSError:
        continue
    if b"\x00" in data[:8192]:
        continue
    try:
        text=data.decode("utf-8")
    except UnicodeDecodeError:
        text=data.decode("utf-8",errors="replace")
    new=redact(text)
    if new != text:
        path.write_text(new,encoding="utf-8")
        changed+=1

print(f"redacted_files={changed}")
