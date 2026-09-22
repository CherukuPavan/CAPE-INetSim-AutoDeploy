#!/usr/bin/env python3
import argparse,json,os,sys
from datetime import datetime
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument("action",choices=["preflight","inspect","acquire","verify","release"])
p.add_argument("--label",default="")
p.add_argument("--deployment-id",required=True)
p.add_argument("--guard-file",required=True)
a=p.parse_args()

from sqlalchemy import select
from lib.cuckoo.core.database import Database, init_database
from lib.cuckoo.core.data.machines import Machine
from lib.cuckoo.core.data.db_common import _utcnow_naive
from lib.cuckoo.core.data.task import (
    Task,TASK_RUNNING,TASK_DISTRIBUTED,TASK_COMPLETED,TASK_DISTRIBUTED_COMPLETED,
)

# COMPLETED / DISTRIBUTED_COMPLETED are deliberately treated as busy because
# CAPE may still be processing/reporting them. This is conservative by design.
#
# CAPE versions are not perfectly uniform here: some define the
# TASK_DISTRIBUTED_COMPLETED constant while omitting that literal from the
# SQLAlchemy/PostgreSQL status_type enum. Sending an unsupported enum literal
# to PostgreSQL aborts the maintenance query before we can acquire a safe lock.
# Filter the candidate set through the installed model's declared enum values.
ACTIVE_CANDIDATES=(TASK_RUNNING,TASK_DISTRIBUTED,TASK_COMPLETED,TASK_DISTRIBUTED_COMPLETED)
MODEL_STATUS_ENUMS=set(getattr(Task.__table__.c.status.type,"enums",()) or ())
ACTIVE=tuple(s for s in ACTIVE_CANDIDATES if not MODEL_STATUS_ENUMS or s in MODEL_STATUS_ENUMS)
if not ACTIVE:
    raise RuntimeError("CAPE task model exposes no supported active task statuses")
if a.action=="preflight":
    # Exercise the real helper imports under CAPE's identity before staging a
    # VM. Do not initialize the database, acquire locks, or create guard files.
    import sqlalchemy
    print(json.dumps({"ready":True,"python":sys.executable,
        "prefix":sys.prefix,"base_prefix":sys.base_prefix,
        "sqlalchemy":sqlalchemy.__version__,"cwd":os.getcwd(),
        "active_statuses":ACTIVE},sort_keys=True))
    raise SystemExit(0)
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

def dt_dump(v):
    return v.isoformat(timespec="microseconds") if v is not None else None

def dt_load(v):
    return datetime.fromisoformat(v) if v else None

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


if a.action=="verify":
    try:
        state=json.load(open(a.guard_file))
    except FileNotFoundError:
        output({"valid":False,"reason":"no-guard-file"},4)
    if state.get("schema") != 2 or not state.get("acquired"):
        output({"valid":False,"reason":"unsupported-or-invalid-guard"},4)
    if state.get("deployment_id") != a.deployment_id:
        output({"valid":False,"reason":"guard-belongs-to-different-deployment"},4)
    marker=state.get("maintenance_locked_changed_on")
    expected={m.get("label") for m in state.get("machines",[]) if m.get("label")}
    with session.begin():
        tasks=task_rows(session)
        machines=machine_rows(session,lock=True)
        current={m.label for m in machines}
        mismatches=[]
        if current != expected:
            mismatches.append({
                "machine_set_changed":True,
                "expected":sorted(expected),
                "current":sorted(current),
            })
        for m in machines:
            if m.label not in expected:
                continue
            if not m.locked or dt_dump(m.locked_changed_on) != marker:
                mismatches.append({
                    "label":m.label,
                    "locked":bool(m.locked),
                    "locked_changed_on":dt_dump(m.locked_changed_on),
                })
        if tasks:
            mismatches.append({
                "active_tasks":[{"id":t.id,"status":t.status,"machine":t.machine} for t in tasks]
            })
    if mismatches:
        output({"valid":False,"reason":"maintenance-ownership-mismatch","mismatches":mismatches},20)
    output({"valid":True,"machine_count":len(expected),"marker":marker})

if a.action=="acquire":
    Path(a.guard_file).parent.mkdir(parents=True,exist_ok=True)
    pending=a.guard_file+".pending"

    # Crash recovery for the narrow window between writing the pre-commit
    # recovery record and atomically publishing the post-commit guard. Because
    # the DB transaction is atomic, the rows must match either the original
    # state (commit never happened) or the deployment lock marker (commit did).
    if not os.path.exists(a.guard_file) and os.path.exists(pending):
        try:
            staged=json.load(open(pending))
        except Exception as exc:
            output({"acquired":False,"reason":"invalid-pending-guard","error":str(exc)},23)
        if staged.get("schema") != 2 or staged.get("deployment_id") != a.deployment_id or not staged.get("acquired"):
            output({"acquired":False,"reason":"pending-guard-identity-mismatch"},23)
        marker=staged.get("maintenance_locked_changed_on")
        expected={m.get("label"):m for m in staged.get("machines",[]) if m.get("label")}
        with session.begin():
            tasks=task_rows(session)
            machines=machine_rows(session,lock=True)
            current={m.label:m for m in machines}
            if set(current) != set(expected):
                output({"acquired":False,"reason":"pending-machine-set-mismatch"},23)
            committed=True
            original=True
            for label,old in expected.items():
                m=current[label]
                if not (m.locked and dt_dump(m.locked_changed_on)==marker):
                    committed=False
                if bool(m.locked) != bool(old.get("locked",False)) or dt_dump(m.locked_changed_on) != old.get("locked_changed_on"):
                    original=False
            if tasks:
                committed=False
                original=False
        if committed:
            os.replace(pending,a.guard_file)
            output({"acquired":True,"recovered":True,"machine_count":len(expected),"marker":marker})
        if original:
            os.unlink(pending)
        else:
            output({"acquired":False,"reason":"pending-guard-partial-state"},23)

    original=[]
    with session.begin():
        # CAPE selects machine rows FOR UPDATE before assigning work. Taking all
        # machine row locks first makes the transition atomic with respect to new
        # assignments. We only change the scheduler locked fields; machine
        # status is left untouched to minimize interference with CAPE internals.
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
            print(json.dumps(result,sort_keys=True))
            raise SystemExit(20)
        if a.label and not any(m.label==a.label for m in machines):
            print(json.dumps({"acquired":False,"reason":"selected-machine-not-in-database","label":a.label},sort_keys=True))
            raise SystemExit(22)

        marker=_utcnow_naive()
        marker_text=dt_dump(marker)
        for m in machines:
            original.append({
                "id":m.id,
                "label":m.label,
                "locked":bool(m.locked),
                "locked_changed_on":dt_dump(m.locked_changed_on),
                "status":m.status,
                "status_changed_on":dt_dump(m.status_changed_on),
            })
            m.locked=True
            m.locked_changed_on=marker

        # Prepare the recovery record before commit. It becomes authoritative only
        # after this transaction commits and the rename below succeeds.
        with open(pending,"w") as fh:
            json.dump({
                "schema":2,
                "deployment_id":a.deployment_id,
                "acquired":True,
                "maintenance_locked_changed_on":marker_text,
                "machines":original,
            },fh,sort_keys=True)
            fh.write("\n")
        os.chmod(pending,0o600)

    # Transaction has committed successfully at this point.
    os.replace(pending,a.guard_file)
    output({"acquired":True,"machine_count":len(original),"marker":marker_text})

if a.action=="release":
    try:
        state=json.load(open(a.guard_file))
    except FileNotFoundError:
        output({"released":True,"reason":"no-guard-file"})

    if state.get("schema") != 2 or not state.get("acquired"):
        output({"released":False,"reason":"unsupported-or-invalid-guard"},4)
    if state.get("deployment_id") != a.deployment_id:
        output({"released":False,"reason":"guard-belongs-to-different-deployment"},4)
    marker=state.get("maintenance_locked_changed_on")
    if not marker:
        output({"released":False,"reason":"guard-missing-lock-marker"},4)

    warnings=[]
    with session.begin():
        by_label={m.label:m for m in machine_rows(session,lock=True)}
        for old in state.get("machines",[]):
            m=by_label.get(old["label"])
            if m is None:
                warnings.append(f"machine disappeared: {old['label']}")
                continue

            # Do not overwrite a machine that CAPE/operator touched after our
            # acquisition. The unique timestamp marker is our ownership proof.
            current_marker=dt_dump(m.locked_changed_on)
            if not m.locked or current_marker != marker:
                warnings.append(f"machine lock changed externally; not touching: {m.label}")
                continue

            m.locked=bool(old.get("locked",False))
            m.locked_changed_on=dt_load(old.get("locked_changed_on"))
            # We intentionally never changed status/status_changed_on.

    if warnings:
        # Keep the guard file for deterministic follow-up/recovery. Removing it
        # here would lose the proof required to resolve a partial release.
        output({"released":False,"warnings":warnings},3)

    try: os.unlink(a.guard_file)
    except FileNotFoundError: pass
    output({"released":True,"warnings":[]})
