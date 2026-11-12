#!/usr/bin/env python3
"""SAS Toddle -> Google Tasks ("School" list) sync.

Usage:
  sas_tasks.py auth-url | auth-code URL     # one-time sign-in
  sas_tasks.py check
  sas_tasks.py sync [--dry-run]             # deterministic: Toddle calendar + Toddle reminder/due-change emails
  sas_tasks.py list                         # open tasks in School list
  sas_tasks.py ann-ids                      # monitor: ids of unseen Toddle announcement emails (or "none")
  sas_tasks.py announcements                # print unseen announcements + open tasks, mark them seen
  sas_tasks.py add TITLE DUE_YYYY-MM-DD [NOTES]   # dedup-checked add (used by the agent), notifies
  sas_tasks.py notify TITLE MSG
"""
import base64, datetime as dt, html, json, re, subprocess, sys, unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sas_google  # noqa: E402  shared sign-in

HOME = Path.home() / ".hermes"
CLIENT = HOME / "google_client_secret.json"
TOKEN = sas_google.TOKEN
STATE = HOME / "sas_tasks_state.json"
SCOPES = [
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/calendar.readonly",
    "https://www.googleapis.com/auth/tasks",
]
REDIRECT = "http://localhost:1"
LIST_NAME = "School"
TZ = dt.timezone(dt.timedelta(hours=8))  # Asia/Singapore
CONFIG = HOME / "sas_bulletins/config.json"
_APPS = Path.home() / "Applications/SAS Sync.app/Contents"
_TN = [_APPS / "Helpers/SAS Sync Notifier.app/Contents/MacOS/terminal-notifier",
       Path("/opt/homebrew/bin/terminal-notifier")]
TN = str(next((p for p in _TN if p.exists()), _TN[-1]))


def config():
    try:
        c = json.loads(CONFIG.read_text())
    except Exception:
        c = {}
    return {"notifications": c.get("tasks_notifications", True),
            "lookahead": int(c.get("tasks_lookahead_days", 28))}
ID_RE = re.compile(r"toddle-id: (\S+)")


# ---------- auth ----------
def creds():
    return sas_google.creds()


def svc(name, ver):
    return sas_google.service(name, ver)


def auth_url():
    sas_google.auth_url()


def auth_code(raw):
    sas_google.auth_code(raw)


# ---------- helpers ----------
def state():
    s = json.loads(STATE.read_text()) if STATE.exists() else {}
    s.setdefault("emails", []); s.setdefault("ann", [])
    return s


def save_state(s):
    s["emails"] = s["emails"][-500:]; s["ann"] = s["ann"][-300:]
    STATE.write_text(json.dumps(s, ensure_ascii=False))


def norm(t):
    t = unicodedata.normalize("NFKC", t or "").lower()
    t = re.sub(r"^\s*(\[optional\]|optional:)\s*", "", t)
    return re.sub(r"[\W_]+", "", t)


def notify(title, msg):
    if Path(TN).exists():
        subprocess.run([TN, "-title", title, "-message", msg, "-sound", "Glass",
                        "-group", "sas-tasks", "-open", "https://tasks.google.com/"])
    else:
        s = lambda x: x.replace("\\", "\\\\").replace('"', '\\"')
        subprocess.run(["osascript", "-e",
                        f'display notification "{s(msg)}" with title "{s(title)}" sound name "Glass"'])


def notify_added(added, updated=()):
    if (not added and not updated) or not config()["notifications"]:
        return
    parts = []
    if added:
        parts.append("; ".join(f"{t} ({d[5:]})" for t, d in added))
    if updated:
        parts.append("Due changed: " + "; ".join(f"{t} → {d[5:]}" for t, d in updated))
    title = f"📚 {len(added)} new school task{'s' if len(added) != 1 else ''}" if added else "📚 School task updated"
    msg = " | ".join(parts)
    notify(title, msg[:240] + ("…" if len(msg) > 240 else ""))


class Tasks:
    def __init__(self):
        self.t = svc("tasks", "v1")
        lists = self.t.tasklists().list(maxResults=100).execute().get("items", [])
        self.all_lists = lists
        sch = next((l for l in lists if l["title"].strip().lower() == LIST_NAME.lower()), None)
        if not sch:
            sch = self.t.tasklists().insert(body={"title": LIST_NAME}).execute()
            self.all_lists.append(sch)
        self.lid = sch["id"]
        self.items = []  # (listid, task) across ALL lists, incl. completed, for dedupe
        for l in self.all_lists:
            tok = None
            while True:
                r = self.t.tasks().list(tasklist=l["id"], showCompleted=True, showHidden=True,
                                        maxResults=100, pageToken=tok).execute()
                self.items += [(l["id"], x) for x in r.get("items", [])]
                tok = r.get("nextPageToken")
                if not tok:
                    break

    def find(self, title=None, tid=None):
        n = norm(title) if title else None
        for lid, x in self.items:
            m = ID_RE.search(x.get("notes") or "")
            if tid and m and m.group(1) == tid:
                return lid, x
            if n and norm(x.get("title")) == n:
                return lid, x
        return None

    def add(self, title, due, notes, dry=False):
        body = {"title": title, "notes": notes, "due": f"{due}T00:00:00.000Z"}
        x = dict(body, id="dry") if dry else self.t.tasks().insert(tasklist=self.lid, body=body).execute()
        self.items.append((self.lid, x))
        return x

    def set_due(self, lid, x, due, dry=False):
        if not dry:
            self.t.tasks().patch(tasklist=lid, task=x["id"], body={"due": f"{due}T00:00:00.000Z"}).execute()
        x["due"] = f"{due}T00:00:00.000Z"


# ---------- sources ----------
def calendar_tasks():
    cal = svc("calendar", "v3")
    cals = [c for c in cal.calendarList().list().execute()["items"]
            if "toddle" in (c.get("summary") or "").lower()]
    start = dt.datetime.now(TZ).replace(hour=0, minute=0, second=0, microsecond=0)
    out = []
    for c in cals:
        tok = None
        while True:
            r = cal.events().list(calendarId=c["id"], timeMin=start.isoformat(),
                                  timeMax=(start + dt.timedelta(days=config()["lookahead"])).isoformat(),
                                  singleEvents=True, orderBy="startTime", maxResults=250, pageToken=tok).execute()
            for e in r.get("items", []):
                desc = e.get("description") or ""
                tt = re.search(r"Task Type:\s*(.+)", desc)
                if not tt:  # "Event Type:" = holidays/tutorials — not actionable
                    continue
                cls = re.search(r"Classes:\s*(.+)", desc)
                link = re.search(r"View Task:\s*(\S+)", desc)
                st = e["start"].get("dateTime") or e["start"].get("date")
                if "T" in st:
                    d = dt.datetime.fromisoformat(st).astimezone(TZ)
                    due, when = d.date().isoformat(), d.strftime("%a %b %-d, %-I:%M %p")
                else:
                    due, when = st, st
                notes = [f"{cls.group(1).strip() if cls else ''} · {tt.group(1).strip()}", f"Due: {when}"]
                dm = re.search(r"Description:\s*(.+)", desc)
                if dm:
                    notes.append(dm.group(1).strip()[:300])
                if link:
                    notes.append(link.group(1))
                notes.append(f"toddle-id: {e.get('iCalUID') or e['id']}")
                out.append({"title": e["summary"].strip(), "due": due, "notes": "\n".join(notes)})
            tok = r.get("nextPageToken")
            if not tok:
                break
    return out


def _hdr(m):
    return {h["name"].lower(): h["value"] for h in m["payload"]["headers"]}


def email_tasks(st):
    """Toddle 'due tomorrow' reminders and due-date-updated emails not yet processed."""
    g = svc("gmail", "v1")
    q = 'from:toddleapp.com newer_than:4d (subject:"Task due tomorrow" OR subject:"Due date updated")'
    ids = [m["id"] for m in g.users().messages().list(userId="me", q=q, maxResults=100).execute().get("messages", [])]
    out = []
    for mid in ids:
        if mid in st["emails"]:
            continue
        m = g.users().messages().get(userId="me", id=mid, format="metadata",
                                     metadataHeaders=["Subject", "Date"]).execute()
        sub, snip = _hdr(m).get("subject", ""), html.unescape(m.get("snippet", ""))
        sent = dt.datetime.fromtimestamp(int(m["internalDate"]) / 1000, TZ)
        tm = re.search(r"'(.+)'", sub)
        if not tm:
            out.append({"mid": mid, "skip": True}); continue
        title = tm.group(1).strip().strip('"')
        link = f"https://mail.google.com/mail/u/0/#all/{m['threadId']}"
        if "due tomorrow" in sub.lower():
            cm = re.search(r"submission (.+?) Reminder to submit", snip)
            due = (sent.date() + dt.timedelta(days=1)).isoformat()
            out.append({"mid": mid, "kind": "new", "title": title, "due": due,
                        "notes": f"{cm.group(1).strip() if cm else ''} · from Toddle reminder email\n{link}"})
        else:
            dm = re.search(r"updated to:?\s*(\d{1,2})/(\d{1,2})/(\d{4})", snip)
            cm = re.search(r"\d{4} (.+?) Task due date updated", snip)
            if not dm:
                out.append({"mid": mid, "skip": True}); continue
            due = dt.date(int(dm.group(3)), int(dm.group(2)), int(dm.group(1))).isoformat()
            out.append({"mid": mid, "kind": "update", "title": title, "due": due,
                        "notes": f"{cm.group(1).strip() if cm else ''} · from Toddle due-date email\n{link}"})
    return out


# ---------- commands ----------
def sync(dry=False):
    st = state()
    T = Tasks()
    today = dt.datetime.now(TZ).date().isoformat()
    added, updated = [], []

    for c in calendar_tasks():
        tid = ID_RE.search(c["notes"]).group(1)
        hit = T.find(tid=tid) or T.find(title=c["title"])
        if hit:
            lid, x = hit
            # follow Toddle due-date changes only for tasks this script created
            if x.get("status") != "completed" and ID_RE.search(x.get("notes") or "") \
                    and (x.get("due") or "")[:10] != c["due"]:
                T.set_due(lid, x, c["due"], dry); updated.append((c["title"], c["due"]))
            continue
        T.add(c["title"], c["due"], c["notes"], dry); added.append((c["title"], c["due"]))

    for e in email_tasks(st):
        if not e.get("skip"):
            hit = T.find(title=e["title"])
            if hit:
                lid, x = hit
                if e["kind"] == "update" and x.get("status") != "completed" \
                        and (x.get("due") or "")[:10] != e["due"]:
                    T.set_due(lid, x, e["due"], dry); updated.append((e["title"], e["due"]))
            elif e["due"] >= today:
                T.add(e["title"], e["due"], e["notes"], dry); added.append((e["title"], e["due"]))
        if not dry:
            st["emails"].append(e["mid"])

    if not dry:
        st["last_sync"] = {"time": dt.datetime.now(TZ).timestamp(), "ok": True,
                           "added": [list(x) for x in added], "updated": [list(x) for x in updated]}
        save_state(st)
        notify_added(added, updated)
    for t, d in added:
        print(f"ADDED  {d}  {t}")
    for t, d in updated:
        print(f"DUE->  {d}  {t}")
    if not added and not updated:
        print("NO_CHANGES")


def open_tasks():
    T = Tasks()
    return sorted(((x.get("due") or "")[:10], x["title"]) for lid, x in T.items
                  if lid == T.lid and x.get("status") != "completed")


def ann_list(g):
    q = 'from:toddleapp.com newer_than:4d subject:announcement'
    return [m["id"] for m in g.users().messages().list(userId="me", q=q, maxResults=50).execute().get("messages", [])]


def ann_ids():
    try:
        st = state()
        new = [i for i in ann_list(svc("gmail", "v1")) if i not in st["ann"]]
        print(" ".join(sorted(new)) or "none")
    except Exception as e:
        print(f"error: {type(e).__name__}")


def _walk(part, out):
    mt = part.get("mimeType", "")
    data = part.get("body", {}).get("data")
    if data and mt in ("text/plain", "text/html"):
        out[mt] = out.get(mt, "") + base64.urlsafe_b64decode(data).decode("utf-8", "replace")
    for p in part.get("parts", []) or []:
        _walk(p, out)


def html_to_text(h):
    h = re.sub(r"(?is)<(script|style).*?</\1>", "", h)
    h = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</li>|</tr>|</h\d>", "\n", h)
    h = html.unescape(re.sub(r"<[^>]+>", "", h))
    return re.sub(r"\n\s*\n+", "\n\n", re.sub(r"[ \t\xa0]+", " ", h)).strip()


def announcements(mark=True):
    st = state()
    g = svc("gmail", "v1")
    new = [i for i in ann_list(g) if i not in st["ann"]]
    if not new:
        print("NO_NEW_ANNOUNCEMENTS"); return
    print("OPEN TASKS ALREADY IN 'School' LIST (due | title):")
    for d, t in open_tasks():
        print(f"  {d} | {t}")
    for mid in new:
        m = g.users().messages().get(userId="me", id=mid, format="full").execute()
        h = _hdr(m); parts = {}
        _walk(m["payload"], parts)
        body = html_to_text(parts["text/html"]) if "text/html" in parts else parts.get("text/plain", "")
        print(f"\n=== ANNOUNCEMENT id={mid}\nSUBJECT: {h.get('subject')}\nFROM: {h.get('from')}\n"
              f"DATE: {h.get('date')}\nGMAIL_LINK: https://mail.google.com/mail/u/0/#all/{m['threadId']}\n\n{body[:3000]}")
        st["ann"].append(mid)
    if mark:
        save_state(st)


def add(title, due, notes=""):
    dt.date.fromisoformat(due)
    T = Tasks()
    hit = T.find(title=title)
    if hit:
        print(f"EXISTS: {hit[1]['title']}"); return
    T.add(title, due, notes)
    notify_added([(title, due)])
    print(f"ADDED  {due}  {title}")


def _task_row(lid, x):
    notes = x.get("notes") or ""
    lines = [l for l in notes.splitlines() if l.strip()]
    link = next((l for l in lines if l.startswith("http")), "")
    course = lines[0].split(" · ")[0].strip() if lines else ""
    when = next((l[5:].strip() for l in lines if l.startswith("Due: ")), "")
    return {"id": x["id"], "list": lid, "title": x.get("title", ""), "due": (x.get("due") or "")[:10],
            "when": when, "course": course, "link": link, "notes": notes,
            "completed": x.get("status") == "completed", "toddle": bool(ID_RE.search(notes)) or "Toddle" in notes}


def cmd_json_list():
    T = Tasks()
    rows = [_task_row(lid, x) for lid, x in T.items if lid == T.lid and x.get("status") != "completed"
            and not x.get("deleted")]
    rows.sort(key=lambda r: (r["due"] or "9999", r["title"].lower()))
    print(json.dumps(rows, ensure_ascii=False))


def cmd_json_status():
    out = {"signed_in": False, "offline": False, "error": None, "last_sync": state().get("last_sync")}
    try:
        creds(); out["signed_in"] = True
    except Exception as e:
        if sas_google.is_network_error(e):
            out.update(offline=True, signed_in=TOKEN.exists())
        else:
            out["error"] = f"{type(e).__name__}: {str(e)[:160]}"
    print(json.dumps(out))


def cmd_complete(tid, undo=False):
    T = Tasks()
    lid = next((l for l, x in T.items if x["id"] == tid), T.lid)
    T.t.tasks().patch(tasklist=lid, task=tid,
                      body={"status": "needsAction" if undo else "completed", **({"completed": None} if undo else {})}).execute()
    print(json.dumps({"ok": True}))


if __name__ == "__main__":
    a = sys.argv[1:]
    cmd = a[0] if a else "sync"
    if cmd == "auth-url": auth_url()
    elif cmd == "auth-code": auth_code(a[1])
    elif cmd == "check": creds(); print("AUTHENTICATED; School list id:", Tasks().lid)
    elif cmd == "sync":
        try:
            sync("--dry-run" in a)
            st = state(); st.pop("fail_day", None); save_state(st)
        except Exception as e:
            st = state(); today = dt.date.today().isoformat()
            hint = "Google sign-in expired - open SAS Sync to sign in" \
                if "Refresh" in type(e).__name__ or "invalid_grant" in str(e) else f"{type(e).__name__}: {str(e)[:120]}"
            if st.get("fail_day") != today:  # alert at most once a day
                notify("⚠️ School task sync failed", hint)
                st["fail_day"] = today
            st["last_sync"] = {"time": dt.datetime.now(TZ).timestamp(), "ok": False, "error": hint}
            save_state(st)
            print(f"SYNC_ERROR {type(e).__name__}: {e}")
            sys.exit(1)
    elif cmd == "list":
        for d, t in open_tasks(): print(d, "|", t)
    elif cmd == "ann-ids": ann_ids()
    elif cmd == "announcements": announcements("--peek" not in a)
    elif cmd == "add": add(a[1], a[2], a[3] if len(a) > 3 else "")
    elif cmd == "notify": notify(a[1], a[2])
    elif cmd == "json-list": cmd_json_list()
    elif cmd == "json-status": cmd_json_status()
    elif cmd == "complete": cmd_complete(a[1], "--undo" in a)
    else: sys.exit(__doc__)
