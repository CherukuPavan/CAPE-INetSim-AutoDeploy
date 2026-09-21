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
init_database(exists_ok=True)
db=Database()
session=db.session

def task_rows(sess):
    return list(sess.scalars(select(Task).where(Task.status.in_(ACTIVE))).all())

def machine_rows(sess, lock=False):
    stmt=select(Machine).order_by(Machine.id)
    if lock:
        stmt=stmt.with_for_update(of=Machine)
    return list(sess.scalars(stmt).all())

def output(obj,rc=0):
    print(json.dumps(obj,sort_keys=True))
    raise SystemExit(rc)

if a.action=="inspect":
    with session.begin():
        tasks=task_rows(session)
        machines=machine_rows(session)
        result={
            "safe": not tasks and not any(m.locked for m in machines),
            "active_tasks":[{"id":t.id,"status":t.status,"machine":t.machine} for t in tasks],
            "machines":[{"id":m.id,"label":m.label,"locked":bool(m.locked),"status":m.status} for m in machines],
        }
    output(result)

if a.action=="acquire":
    Path(a.guard_file).parent.mkdir(parents=True,exist_ok=True)
    pending=a.guard_file+".pending"
    original=[]
    with session.begin():
        # CAPE's scheduler selects machine rows FOR UPDATE before assigning work.
        # Taking every machine row lock first makes this maintenance acquisition
        # atomic with respect to new analysis assignment.
        machines=machine_rows(session,lock=True)
        tasks=task_rows(session)
        locked=[m for m in machines if m.locked]
        if tasks or locked:
            result={
                "acquired":False,
                "reason":"busy",
                "active_tasks":[{"id":t.id,"status":t.status,"machine":t.machine} for t in tasks],
                "locked_machines":[{"id":m.id,"label":m.label,"status":m.status} for m in locked],
            }
            # Raising here intentionally rolls back this read/lock transaction.
            print(json.dumps(result,sort_keys=True))
            raise SystemExit(20)
        if a.label and not any(m.label==a.label for m in machines):
            print(json.dumps({"acquired":False,"reason":"selected-machine-not-in-database","label":a.label},sort_keys=True))
            raise SystemExit(22)

        for m in machines:
            original.append({"id":m.id,"label":m.label,"locked":bool(m.locked),"status":m.status})
            m.locked=True
            m.locked_changed_on=_utcnow_naive()
            m.status="autodeploy-maintenance"
            m.status_changed_on=_utcnow_naive()

        # Prepare the recovery record before commit. It becomes authoritative only
        # after this transaction commits and the rename below succeeds.
        with open(pending,"w") as fh:
            json.dump({"schema":1,"acquired":True,"machines":original},fh,sort_keys=True)
            fh.write("\n")
        os.chmod(pending,0o600)

    # Transaction has committed successfully at this point.
    os.replace(pending,a.guard_file)
    output({"acquired":True,"machine_count":len(original)})

if a.action=="release":
    try:
        state=json.load(open(a.guard_file))
    except FileNotFoundError:
        output({"released":True,"reason":"no-guard-file"})

    warnings=[]
    with session.begin():
        by_label={m.label:m for m in machine_rows(session,lock=True)}
        for old in state.get("machines",[]):
            m=by_label.get(old["label"])
            if m is None:
                warnings.append(f"machine disappeared: {old['label']}")
                continue
            # Never overwrite a machine that CAPE/operator changed after acquire.
            if not m.locked or m.status!="autodeploy-maintenance":
                warnings.append(f"machine changed externally; not touching: {m.label}")
                continue
            m.locked=bool(old.get("locked",False))
            m.locked_changed_on=_utcnow_naive()
            m.status=old.get("status")
            m.status_changed_on=_utcnow_naive()

    try: os.unlink(a.guard_file)
    except FileNotFoundError: pass
    output({"released":True,"warnings":warnings},0 if not warnings else 3)
