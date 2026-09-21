#!/usr/bin/env python3
import argparse,json,os,sys
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument("action",choices=["inspect","acquire","release"])
p.add_argument("--label",default="")
p.add_argument("--guard-file",required=True)
a=p.parse_args()

from sqlalchemy import select
from lib.cuckoo.core.database import Database, init_database
from lib.cuckoo.core.data.machines import Machine
from lib.cuckoo.core.data.db_common import _utcnow_naive
from lib.cuckoo.core.data.task import (
    Task,TASK_RUNNING,TASK_DISTRIBUTED,TASK_COMPLETED,TASK_DISTRIBUTED_COMPLETED,
)

ACTIVE={TASK_RUNNING,TASK_DISTRIBUTED,TASK_COMPLETED,TASK_DISTRIBUTED_COMPLETED}
db=init_database(exists_ok=True)
facade=Database()
session=facade.session

def task_rows(sess):
    return list(sess.scalars(select(Task).where(Task.status.in_(ACTIVE))).all())

def machine_rows(sess, lock=False):
    stmt=select(Machine).order_by(Machine.id)
    if lock:
        stmt=stmt.with_for_update(of=Machine)
    return list(sess.scalars(stmt).all())

def emit(obj,rc=0):
    print(json.dumps(obj,sort_keys=True))
    raise SystemExit(rc)

if a.action=="inspect":
    with session.begin():
        tasks=task_rows(session)
        machines=machine_rows(session)
        emit({
            "safe": not tasks and not any(m.locked for m in machines),
            "active_tasks":[{"id":t.id,"status":t.status,"machine":t.machine} for t in tasks],
            "machines":[{"id":m.id,"label":m.label,"locked":bool(m.locked),"status":m.status} for m in machines],
        })

if a.action=="acquire":
    Path(a.guard_file).parent.mkdir(parents=True,exist_ok=True)
    with session.begin():
        # Lock every machine row first. This serializes against CAPE's scheduler,
        # which also selects machine rows FOR UPDATE before assigning work.
        machines=machine_rows(session,lock=True)
        tasks=task_rows(session)
        locked=[m for m in machines if m.locked]
        if tasks or locked:
            emit({
                "acquired":False,
                "reason":"busy",
                "active_tasks":[{"id":t.id,"status":t.status,"machine":t.machine} for t in tasks],
                "locked_machines":[{"id":m.id,"label":m.label,"status":m.status} for m in locked],
            },20)
        if a.label and not any(m.label==a.label for m in machines):
            emit({"acquired":False,"reason":"selected-machine-not-in-database","label":a.label},22)

        original=[]
        for m in machines:
            original.append({"id":m.id,"label":m.label,"locked":bool(m.locked),"status":m.status})
            m.locked=True
            m.locked_changed_on=_utcnow_naive()
            m.status="autodeploy-maintenance"
            m.status_changed_on=_utcnow_naive()
        state={"schema":1,"acquired":True,"machines":original}
        tmp=a.guard_file+".tmp"
        with open(tmp,"w") as f:
            json.dump(state,f,sort_keys=True)
            f.write("\n")
        os.chmod(tmp,0o600)
        os.replace(tmp,a.guard_file)
    emit({"acquired":True,"machine_count":len(machines)})

if a.action=="release":
    try:
        state=json.load(open(a.guard_file))
    except FileNotFoundError:
        emit({"released":True,"reason":"no-guard-file"})
    warnings=[]
    with session.begin():
        by_label={m.label:m for m in machine_rows(session,lock=True)}
        for old in state.get("machines",[]):
            m=by_label.get(old["label"])
            if m is None:
                warnings.append(f"machine disappeared: {old['label']}")
                continue
            # Only undo our maintenance marker. Never overwrite a machine that CAPE
            # or an operator has changed since acquisition.
            if not m.locked or m.status!="autodeploy-maintenance":
                warnings.append(f"machine changed externally; not touching: {m.label}")
                continue
            m.locked=bool(old.get("locked",False))
            m.locked_changed_on=_utcnow_naive()
            m.status=old.get("status")
            m.status_changed_on=_utcnow_naive()
    try: os.unlink(a.guard_file)
    except FileNotFoundError: pass
    emit({"released":True,"warnings":warnings},0 if not warnings else 3)
