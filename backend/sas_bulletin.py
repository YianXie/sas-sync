#!/usr/bin/env python3
"""SAS HS Daily Bulletin fetcher (read-only Gmail access).

Usage:
  sas_bulletin.py auth-url          # print sign-in URL
  sas_bulletin.py auth-code URL     # finish sign-in with redirected URL/code
  sas_bulletin.py check             # verify token works
  sas_bulletin.py latest-id         # print id of newest bulletin (monitor; deterministic)
  sas_bulletin.py fetch [--force]   # print newest unsummarized bulletin body, mark it seen
  sas_bulletin.py notify TITLE MSG  # macOS notification
"""
import base64, datetime, html, json, re, shutil, subprocess, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sas_google  # noqa: E402  shared sign-in

HOME = Path.home() / ".hermes"
CLIENT = HOME / "google_client_secret.json"
TOKEN = sas_google.TOKEN
PENDING = HOME / "sas_gmail_pending.json"
STATE = HOME / "sas_bulletin_state.json"
SCOPES = ["https://www.googleapis.com/auth/gmail.readonly"]
REDIRECT = "http://localhost:1"
QUERY = 'subject:"HS Daily Bulletin" newer_than:7d'


def service():
    return sas_google.service("gmail", "v1")


def auth_url():
    sas_google.auth_url()


def auth_code(raw):
    sas_google.auth_code(raw)


def latest(svc):
    r = svc.users().messages().list(userId="me", q=QUERY, maxResults=1).execute()
    m = r.get("messages") or []
    return m[0]["id"] if m else None


def _walk(part, out):
    mt = part.get("mimeType", "")
    data = part.get("body", {}).get("data")
    if data and mt in ("text/plain", "text/html"):
        out.setdefault(mt, "")
        out[mt] += base64.urlsafe_b64decode(data).decode("utf-8", "replace")
    for p in part.get("parts", []) or []:
        _walk(p, out)


def html_to_text(h):
    h = re.sub(r"(?is)<(script|style).*?</\1>", "", h)
    h = re.sub(r'(?is)<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>', r"\2 (\1)", h)
    h = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</li>|</tr>|</h\d>", "\n", h)
    h = re.sub(r"(?i)<li[^>]*>", "- ", h)
    h = html.unescape(re.sub(r"<[^>]+>", "", h))
    return re.sub(r"\n\s*\n+", "\n\n", re.sub(r"[ \t\xa0]+", " ", h)).strip()


def get_message(svc, mid):
    m = svc.users().messages().get(userId="me", id=mid, format="full").execute()
    hdr = {h["name"].lower(): h["value"] for h in m["payload"]["headers"]}
    parts = {}
    _walk(m["payload"], parts)
    body = html_to_text(parts["text/html"]) if "text/html" in parts else parts.get("text/plain", "")
    return m, hdr, body


def _is_heading(line):
    s = line.strip()
    head = re.split(r"\s[-–]\s", s)[0]
    letters = [c for c in head if c.isalpha()]
    return len(letters) >= 8 and sum(c.isupper() for c in letters) / len(letters) >= 0.85 and len(s) < 140


def _key(line):
    head = re.split(r"\s[-–]\s", line.strip())[0]
    return re.sub(r"[^A-Z0-9]", "", head.upper())


def split_sections(body):
    """Split bulletin text into [(heading, text)] using ALL-CAPS heading lines."""
    secs, cur, buf = [], "INTRO", []
    for line in body.splitlines():
        if _is_heading(line):
            secs.append((cur, "\n".join(buf).strip()))
            cur, buf = line.strip(), []
        else:
            buf.append(line)
    secs.append((cur, "\n".join(buf).strip()))
    return [(h, t) for h, t in secs if t or h != "INTRO"]


def _norm_text(t):
    t = re.sub(r"\(https?://[^)]*\)", "", t)
    return re.sub(r"\W+", " ", t).lower().strip()


NET_ERRORS = ("TransportError", "ConnectionError", "NameResolution", "Timeout", "timed out", "ServerNotFound")


def _is_network_error(e):
    return sas_google.is_network_error(e)


def fetch(force=False, mid=None):
    req = _load_json(REGEN, {})
    regen_mode = bool(req.get("id")) and not req.get("done")
    if regen_mode:
        mid, force = req["id"], True
        req["done"] = True          # consume up front so a bad request can never block daily runs
        REGEN.write_text(json.dumps(req))
    try:
        svc = service()
        ids = svc.users().messages().list(userId="me", q='subject:"HS Daily Bulletin" newer_than:60d',
                                          maxResults=40).execute().get("messages") or []
    except Exception as e:
        if _is_network_error(e):
            print("NO_NEW_BULLETIN")  # offline / asleep: try again next tick, don't alarm
            return
        raise
    ids = [x["id"] for x in ids]
    state = json.loads(STATE.read_text()) if STATE.exists() else {"seen": []}
    mid = mid or (ids[0] if ids else None)
    if not mid or (mid in state["seen"] and not force):
        print("NO_NEW_BULLETIN")
        return
    m, hdr, body = get_message(svc, mid)
    # Compare against up to 4 earlier bulletins to tag sections NEW vs REPEAT
    prev_keys, prev_texts = set(), set()
    older = ids[ids.index(mid) + 1:] if mid in ids else ids[1:]
    for oid in older[:4]:
        for h, t in split_sections(get_message(svc, oid)[2]):
            prev_keys.add(_key(h))
            prev_texts.add(_norm_text(t)[:300])
    out = [f"SUBJECT: {hdr.get('subject')}", f"DATE_RECEIVED: {hdr.get('date')}",
           f"GMAIL_LINK: https://mail.google.com/mail/u/0/#all/{m['threadId']}",
           f"(Sections compared against {min(4, len(older))} previous bulletins.)", ""]
    for h, t in split_sections(body):
        if h in ("INTRO",) or "BULLETIN ARCHIVE" in h.upper():
            tag = "INFO"
        elif _key(h) in prev_keys:
            tag = "REPEAT" if _norm_text(t)[:300] in prev_texts else "REPEAT-UPDATED"
        else:
            tag = "NEW"
        if "Singapore American School" in t and "PEI Registration" in t:
            t = t.split("Singapore American School")[0].strip()
        out.append(f"===== [{tag}] {h}\n{t}\n")
    head = ["===== SETTINGS (JSON, set by Ian in the SAS Bulletin app; obey them) =====",
            json.dumps(load_config(), indent=1), "===== END SETTINGS =====", "",
            f"MODE: {'REGENERATE (Ian asked to re-summarize this specific day)' if regen_mode else 'DAILY'}", ""]
    prof = OUTDIR / "profile.md"
    if prof.exists():
        head += ["===== READER PROFILE (use to rank relevance) =====", prof.read_text().strip(),
                 "===== END PROFILE =====", ""]
    print("\n".join(head + out)[:70000])
    if mid not in state["seen"]:
        state["seen"] = (state["seen"] + [mid])[-60:]
        STATE.write_text(json.dumps(state))
    if regen_mode:
        req["done"] = True
        REGEN.write_text(json.dumps(req))


OUTDIR = HOME / "sas_bulletins"
CONFIG = OUTDIR / "config.json"
REGEN = OUTDIR / "regen_request.json"
LAST_PUB = OUTDIR / "last_publish.json"
JOB_ID = "5234ce72f5b5"
JOBS = {"bulletin": "5234ce72f5b5", "tasks": "2a7f14318718", "announcements": "96cc9fd686dc"}
DEFAULTS = {
    "for_you": True,                       # show the "For you" section
    "for_you_max": 6,                      # max items in "For you"
    "deadline_window_days": 3,             # deadlines this close count as urgent
    "star_deadlines_only_if_relevant": True,  # urgent deadlines only get a star if they match Ian's interests
    "college_list_only": False,            # star only college visits from Ian's list
    "also_new": True,                      # show the "Also new today" section
    "everything_else": True,               # show the folded "Everything else" section
    "notifications": True,                 # macOS pop-up
    "post_to_chat": True,                  # also post the summary to Hermes Bot Chat
    "extra_instructions": "",
    # Toddle assignments (read by sas_tasks.py)
    "tasks_notifications": True,           # pop-up when new assignments are added
    "tasks_lookahead_days": 28,            # how far ahead to read the Toddle calendar
}
_APPS = Path.home() / "Applications/SAS Sync.app/Contents"
_TN_CANDIDATES = [_APPS / "Helpers/SAS Sync Notifier.app/Contents/MacOS/terminal-notifier",
                  _APPS / "MacOS/terminal-notifier", Path("/opt/homebrew/bin/terminal-notifier")]
TN = str(next((p for p in _TN_CANDIDATES if p.exists()), _TN_CANDIDATES[-1]))


def _load_json(path, default):
    try:
        return json.loads(Path(path).read_text())
    except Exception:
        return default


def load_config():
    cfg = dict(DEFAULTS)
    cfg.update({k: v for k, v in _load_json(CONFIG, {}).items() if k in DEFAULTS})
    return cfg


def find_hermes():
    for c in [shutil.which("hermes"), str(HOME / "hermes-agent/.hermes/bin/hermes"),
              str(Path.home() / ".local/bin/hermes"), "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"]:
        if c and Path(c).exists():
            return c
    raise SystemExit("hermes CLI not found")


def _job(jid=JOB_ID):
    for j in _load_json(HOME / "cron/jobs.json", {}).get("jobs", []):
        if j.get("job_id") == jid or j.get("id") == jid:
            return j
    return None


def _job_info(jid):
    j = _job(jid)
    return {"found": bool(j), "enabled": bool(j and j.get("enabled") and j.get("state") != "paused"),
            "next_run": j and j.get("next_run_at"), "last_run": j and j.get("last_run_at"),
            "last_status": j and j.get("last_status")}


def cmd_status():
    out = {"signed_in": False, "offline": False, "email": None, "error": None}
    try:
        prof = service().users().getProfile(userId="me").execute()
        out.update(signed_in=True, email=prof.get("emailAddress"))
    except Exception as e:
        if _is_network_error(e):
            out.update(offline=True, signed_in=TOKEN.exists())
        else:
            out["error"] = f"{type(e).__name__}: {str(e)[:160]}"
    j = _job()
    out.update(job_found=bool(j), job_enabled=bool(j and j.get("enabled") and j.get("state") != "paused"),
               next_run=j and j.get("next_run_at"), last_run=j and j.get("last_run_at"),
               last_status=j and j.get("last_status"))
    req = _load_json(REGEN, {})
    out["regen_pending"] = bool(req.get("id")) and not req.get("done")
    out["regen_id"] = req.get("id")
    out["last_publish"] = _load_json(LAST_PUB, None)
    out["jobs"] = {k: _job_info(v) for k, v in JOBS.items()}
    print(json.dumps(out))


def _stamp_from_subject(subj):
    m = re.search(r"([A-Z][a-z]{2})[a-z]* (\d{1,2}),? (\d{4})", subj or "")
    if not m:
        return None
    try:
        return datetime.datetime.strptime(" ".join(m.groups()), "%b %d %Y").date().isoformat()
    except ValueError:
        return None


def cmd_list():
    svc = service()
    msgs = svc.users().messages().list(userId="me", q='subject:"HS Daily Bulletin" newer_than:60d',
                                       maxResults=40).execute().get("messages") or []
    meta = {}

    def cb(rid, resp, exc):
        if exc is None:
            meta[rid] = resp
    batch = svc.new_batch_http_request(callback=cb)
    for m in msgs:
        batch.add(svc.users().messages().get(userId="me", id=m["id"], format="metadata",
                                             metadataHeaders=["Subject", "Date"]), request_id=m["id"])
    batch.execute()
    seen = set(_load_json(STATE, {"seen": []})["seen"])
    rows = []
    for m in msgs:
        r = meta.get(m["id"])
        if not r:
            continue
        hdr = {h["name"].lower(): h["value"] for h in r["payload"]["headers"]}
        stamp = _stamp_from_subject(hdr.get("subject"))
        page = OUTDIR / f"{stamp}.html" if stamp else None
        rows.append({"id": m["id"], "subject": hdr.get("subject", ""), "received": hdr.get("date", ""),
                     "stamp": stamp or "", "summarized": m["id"] in seen,
                     "has_page": bool(page and page.exists()), "page": str(page) if page else ""})
    rows.sort(key=lambda x: x["stamp"], reverse=True)
    print(json.dumps(rows))


def cmd_regen(mid):
    try:
        service().users().messages().get(userId="me", id=mid, format="minimal").execute()
    except Exception as e:
        print(json.dumps({"ok": False, "output": f"Not a valid bulletin id ({type(e).__name__})"}))
        return
    req = _load_json(REGEN, {})
    req.update(id=mid, counter=int(req.get("counter", 0)) + 1, done=False, requested_at=time.time())
    REGEN.write_text(json.dumps(req))
    r = subprocess.run([find_hermes(), "cron", "run", JOB_ID], capture_output=True, text=True)
    print(json.dumps({"ok": r.returncode == 0, "output": (r.stdout + r.stderr)[-400:]}))


def cmd_schedule(on, which="bulletin"):
    r = subprocess.run([find_hermes(), "cron", "resume" if on else "pause", JOBS[which]], capture_output=True, text=True)
    print(json.dumps({"ok": r.returncode == 0, "output": (r.stdout + r.stderr)[-400:]}))

PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>{title}</title>
<style>
:root{{color-scheme:light dark}}
body{{font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;max-width:760px;margin:40px auto;padding:0 20px}}
h1{{font-size:1.6em;border-bottom:2px solid #c8102e;padding-bottom:.3em}}
p strong{{display:block;font-size:1.15em;margin-top:1.4em}}
li{{margin:.35em 0}} a{{color:#2563eb}} ul{{padding-left:1.3em}}
.nav{{font-size:.85em;opacity:.7;margin-bottom:1em}}
details{{margin-top:2em;border:1px solid #8884;border-radius:8px;padding:.6em 1em}}
summary{{cursor:pointer;font-weight:600;opacity:.8}}
details p strong{{font-size:1em;margin-top:1em}}
</style></head><body><div class="nav">{nav}</div>{body}</body></html>"""


def publish(md_path, title, msg):
    """Render summary markdown to HTML, then show a clickable notification that opens it."""
    import markdown
    md = Path(md_path).read_text()
    md = re.sub(r"(?m)^(\s*)- \[ \] ", r"\1- ☐ ", md)
    md = re.sub(r"(?m)^(\s*)- \[x\] ", r"\1- ☑ ", md)
    md = re.sub(r"(?m)^(\*\*[^*\n]+\*\*[^\n]*)\n(?=\s*- )", r"\1\n\n", md)  # list after heading line
    md = re.sub(r"(?is)<details[^>]*>\s*(<summary>.*?</summary>)?", "<!--more-->", md, count=1)
    md = re.sub(r"(?is)</?details[^>]*>|<summary>.*?</summary>", "", md)  # chat-only folding tags
    conv = lambda s: markdown.markdown(s, extensions=["extra", "sane_lists"])
    top, _, rest = md.partition("<!--more-->")
    tail_link = ""
    m_link = re.search(r"\n(\[Open full bulletin in Gmail\]\([^)]*\))\s*$", rest)
    if m_link:
        tail_link, rest = m_link.group(1), rest[:m_link.start()]
    body = conv(top)
    if rest.strip():
        n = len(re.findall(r"(?m)^\s*- ", rest))
        body += (f'<details><summary>Everything else — still upcoming &amp; repeated ({n})</summary>'
                 f'{conv(rest)}</details>')
    if tail_link:
        body += conv(tail_link)
    body = body.replace("<a href=", '<a target="_blank" href=')
    OUTDIR.mkdir(exist_ok=True)
    dm = re.search(r"([A-Z][a-z]{2})[a-z]* (\d{1,2}),? (\d{4})", title)
    try:
        stamp = datetime.datetime.strptime(" ".join(dm.groups()), "%b %d %Y").date().isoformat()
    except Exception:
        stamp = datetime.date.today().isoformat()
    page = OUTDIR / f"{stamp}.html"
    older = sorted(p.name for p in OUTDIR.glob("20*.html") if p.name != page.name)[-5:]
    nav = "Previous: " + " · ".join(f'<a href="{n}">{n[:-5]}</a>' for n in reversed(older)) if older else ""
    html_doc = PAGE.format(title=html.escape(title), nav=nav, body=body)
    page.write_text(html_doc)
    (OUTDIR / "latest.html").write_text(html_doc)
    LAST_PUB.write_text(json.dumps({"stamp": stamp, "title": title, "time": time.time()}))
    if load_config()["notifications"]:
        notify(title, msg, page.as_uri())
    print(f"OK: {page}")


def notify(title, msg, open_url=None):
    if Path(TN).exists():
        cmd = [TN, "-title", title, "-message", msg, "-sound", "Glass", "-group", "sas-bulletin"]
        if open_url:
            cmd += ["-open", open_url]
        subprocess.run(cmd)
    else:
        s = lambda x: x.replace("\\", "\\\\").replace('"', '\\"')
        subprocess.run(["osascript", "-e", f'display notification "{s(msg)}" with title "{s(title)}" sound name "Glass"'])


if __name__ == "__main__":
    a = sys.argv[1:]
    cmd = a[0] if a else "fetch"
    if cmd == "auth-url": auth_url()
    elif cmd == "auth-code": auth_code(a[1])
    elif cmd == "check": print("AUTHENTICATED, latest bulletin id:", latest(service()))
    elif cmd == "latest-id":
        # Must be stable: on network errors repeat the last good id so the monitor doesn't flap
        cache = HOME / "sas_bulletin_latest_id.txt"
        try:
            v = latest(service()) or "none"
            cache.write_text(v)
            n = int(_load_json(REGEN, {}).get("counter", 0))
            if n:
                v += f"|r{n}"
        except Exception as e:
            v = cache.read_text() if cache.exists() and _is_network_error(e) else f"error: {type(e).__name__}"
        print(v)
    elif cmd == "fetch":
        mid = next((x.split("=", 1)[1] for x in a if x.startswith("--id=")), None)
        fetch("--force" in a, mid)
    elif cmd == "notify": notify(a[1], a[2])
    elif cmd == "publish": publish(a[1], a[2], a[3])  # publish SUMMARY.md TITLE MESSAGE
    elif cmd == "status": cmd_status()
    elif cmd == "list": cmd_list()
    elif cmd == "regen": cmd_regen(a[1])
    elif cmd == "schedule": cmd_schedule(a[1] == "on", a[2] if len(a) > 2 else "bulletin")
    elif cmd == "config": print(json.dumps(load_config()))
