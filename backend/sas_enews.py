#!/usr/bin/env python3
"""SAS weekly eNews (https://www.sas.edu.sg/enews) → personalized summary.

The eNews URL never changes; the page is replaced every Friday afternoon (~3:15 PM). Only the
current issue is online, so every issue we see is archived as raw HTML in ~/.hermes/sas_bulletins/enews/.

Usage:
  sas_enews.py latest-id            # issue date of the live page (cron monitor; stable output)
  sas_enews.py fetch                # print newest unsummarized issue for the LLM (or NO_NEW_ENEWS)
  sas_enews.py publish MD TITLE MSG # render summary markdown → enews/<date>.html + notification
  sas_enews.py list                 # JSON list of archived issues (snapshots the live page first)
  sas_enews.py status               # JSON: regen state + last publish (no network)
  sas_enews.py regen YYYY-MM-DD     # re-summarize an archived issue via the Hermes cron job
"""
import datetime, html, json, re, subprocess, sys, time, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sas_bulletin as sb  # noqa: E402  shared config, profile, publish, notifications, cron helpers

URL = "https://www.sas.edu.sg/enews"
DIR = sb.OUTDIR / "enews"
STATE = DIR / "state.json"            # {"seen": [stamps summarized]}
REGEN = DIR / "regen_request.json"
LAST_PUB = DIR / "last_publish.json"
CACHE_ID = DIR / "latest_id.txt"
JOB_ID = sb.JOBS["enews"]
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) SAS-Sync"

SECTION_NAMES = {
    "Superintendent": "From the Superintendent", "Schoolwide": "Schoolwide",
    "Elementary": "Elementary School", "Middle": "Middle School", "High": "High School",
    "ActivitiesAthletics": "Activities and Athletics", "PTA": "PTA", "Booster": "Booster Club",
    "Community": "Community", "Alumni": "Alumni", "Dining": "Dining",
}
# Hint for the LLM; the reader profile still decides what's actually relevant.
SECTION_PRIORITY = {"High": "HIGH", "Schoolwide": "HIGH", "ActivitiesAthletics": "HIGH", "Booster": "MEDIUM",
                    "Superintendent": "MEDIUM", "Community": "LOW", "PTA": "LOW", "Dining": "LOW",
                    "Middle": "LOW", "Elementary": "LOW", "Alumni": "LOW"}
SKIP_ANCHORS = {"BackToTop", "Calendars"}


# ---------- fetching & parsing ----------

def download():
    req = urllib.request.Request(URL, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")


def issue_stamp(page):
    """Issue date from the first '<h4>Month D, YYYY</h4>' heading → 'YYYY-MM-DD'."""
    m = re.search(r"<h4[^>]*>\s*([A-Z][a-z]+)\s+(\d{1,2}),\s*(\d{4})\s*</h4>", page)
    if not m:
        return None
    try:
        return datetime.datetime.strptime(" ".join(m.groups()), "%B %d %Y").date().isoformat()
    except ValueError:
        return None


def _is_network_error(e):
    return isinstance(e, (OSError, TimeoutError)) or sb._is_network_error(e)


def snapshot():
    """Download the live page and archive it if it's a new issue. Returns stamp (None if offline/unparsable)."""
    DIR.mkdir(parents=True, exist_ok=True)
    page = download()
    stamp = issue_stamp(page)
    if not stamp:
        raise RuntimeError("could not find the issue date on the eNews page (layout changed?)")
    raw = DIR / f"{stamp}.raw.html"
    if not raw.exists() or raw.read_text() != page:
        raw.write_text(page)
    CACHE_ID.write_text(stamp)
    return stamp


def parse(page, prev_links=frozenset()):
    """Return {stamp, title, banner, sections: [{key, name, priority, text}], links: set}."""
    stamp = issue_stamp(page)
    m = re.search(r"<h4[^>]*>\s*[A-Z][a-z]+\s+\d{1,2},\s*\d{4}\s*</h4>", page)
    start = m.start() if m else 0
    end = min([i for i in (page.find("Schoolwide Calendars", start), page.find('id="fsFooter"', start)) if i > 0]
              or [len(page)])
    body = page[start:end]
    banner = ""
    bm = re.search(r"</h4>\s*<h6[^>]*>(.*?)</h6>", body, re.S)
    if bm:
        banner = sb.html_to_text(bm.group(1))
    anchors = [(a.start(), a.group(1)) for a in re.finditer(r'<a\s+id="(\w+)"\s+name="\1"', body)
               if a.group(1) not in SKIP_ANCHORS]
    links = set()

    def post_title(mt):
        url, title = mt.group(1), sb.html_to_text(mt.group(2))
        links.add(url)
        tag = "REPEAT" if url in prev_links else "NEW"
        return f"\n\n### [{tag}] {title}\nLINK: {url}\n"

    sections = []
    for i, (pos, key) in enumerate(anchors):
        chunk = body[pos:anchors[i + 1][0] if i + 1 < len(anchors) else len(body)]
        chunk = re.sub(r'(?is)<div class="fsTitle[^"]*"[^>]*>\s*<a class="fsPostLink"[^>]*href="([^"]+)"[^>]*>(.*?)</a>\s*</div>',
                       post_title, chunk)
        chunk = re.sub(r'(?is)<div class="fsTitle[^"]*"[^>]*>(.*?)</div>', r"\n\n### \1\n", chunk)
        chunk = re.sub(r"(?is)<iframe[^>]*youtube[^>]*></iframe>", "\n(video)\n", chunk)
        text = sb.html_to_text(chunk)
        text = re.sub(r"(?m)^\s*Back to Top \(#BackToTop\)\s*$", "", text)
        text = re.sub(r"\(#\w+\)", "", text)
        text = re.sub(r"\n{3,}", "\n\n", text).strip()
        sections.append({"key": key, "name": SECTION_NAMES.get(key, re.sub(r"(?<!^)(?=[A-Z])", " ", key)),
                         "priority": SECTION_PRIORITY.get(key, "MEDIUM"), "text": text})
    title = f"SAS eNews – {_human(stamp)}" if stamp else "SAS eNews"
    return {"stamp": stamp, "title": title, "banner": banner, "sections": sections, "links": links}


def _human(stamp):
    d = datetime.date.fromisoformat(stamp)
    return f"{d:%B} {d.day}, {d.year}"


def archived():
    """Sorted (newest first) list of archived issue stamps."""
    return sorted((p.name[:10] for p in DIR.glob("20??-??-??.raw.html")), reverse=True)


def _prev_links(stamp):
    older = [s for s in archived() if s < stamp]
    if not older:
        return frozenset()
    return frozenset(parse((DIR / f"{older[0]}.raw.html").read_text())["links"])


# ---------- commands ----------

def cmd_latest_id():
    """Stable monitor output: issue date (+ regen counter). Repeats last good value when offline."""
    try:
        v = snapshot()
    except Exception as e:
        v = CACHE_ID.read_text().strip() if CACHE_ID.exists() and _is_network_error(e) else f"error: {type(e).__name__}"
    n = int(sb._load_json(REGEN, {}).get("counter", 0))
    print(v + (f"|r{n}" if n and not v.startswith("error") else ""))


def cmd_fetch():
    req = sb._load_json(REGEN, {})
    regen_mode = bool(req.get("id")) and not req.get("done")
    if regen_mode:
        req["done"] = True          # consume up front so a bad request can never block weekly runs
        REGEN.write_text(json.dumps(req))
    try:
        stamp = snapshot()
    except Exception as e:
        if not (regen_mode or _is_network_error(e)):
            raise
        stamp = None
    state = sb._load_json(STATE, {"seen": []})
    if regen_mode:
        stamp = req["id"]
    if not stamp or not (DIR / f"{stamp}.raw.html").exists() or (stamp in state["seen"] and not regen_mode):
        print("NO_NEW_ENEWS")
        return
    issue = parse((DIR / f"{stamp}.raw.html").read_text(), _prev_links(stamp))
    cfg = sb.load_config()
    head = ["===== SETTINGS (JSON, set by Ian in the SAS Sync app; obey them) =====",
            json.dumps({k: cfg[k] for k in ("for_you_max", "enews_extra_instructions", "enews_post_to_chat",
                                            "enews_include_other_divisions")}, indent=1),
            "===== END SETTINGS =====", "",
            f"MODE: {'REGENERATE (Ian asked to re-summarize this issue)' if regen_mode else 'WEEKLY'}", ""]
    prof = sb.OUTDIR / "profile.md"
    if prof.exists():
        head += ["===== READER PROFILE (use to rank relevance) =====", prof.read_text().strip(),
                 "===== END PROFILE =====", ""]
    out = [f"ISSUE_DATE: {_human(stamp)} ({stamp})", f"TITLE: {issue['title']}", f"ENEWS_LINK: {URL}",
           f"BANNER: {issue['banner'] or '-'}",
           "(Posts are tagged [NEW] or [REPEAT] = also in the previous archived issue.)", ""]
    for s in issue["sections"]:
        if not cfg["enews_include_other_divisions"] and s["key"] in ("Elementary", "Middle", "Alumni"):
            out.append(f"===== SECTION: {s['name']} [priority {s['priority']}] — omitted by settings\n")
            continue
        out.append(f"===== SECTION: {s['name']} [priority {s['priority']}]\n{s['text']}\n")
    print("\n".join(head + out)[:80000])
    if stamp not in state["seen"]:
        state["seen"] = (state["seen"] + [stamp])[-60:]
        STATE.write_text(json.dumps(state))


def cmd_publish(md_path, title, msg):
    sb.publish(md_path, title, msg if sb.load_config()["enews_notifications"] else None,
               outdir=DIR, last_pub=LAST_PUB, group="sas-enews", write_latest=False)


def cmd_list():
    live_error = None
    try:
        snapshot()
    except Exception as e:
        live_error = "offline" if _is_network_error(e) else f"{type(e).__name__}: {str(e)[:160]}"
    seen = set(sb._load_json(STATE, {"seen": []})["seen"])
    live = CACHE_ID.read_text().strip() if CACHE_ID.exists() else None
    rows = []
    for stamp in archived():
        page = DIR / f"{stamp}.html"
        rows.append({"id": stamp, "stamp": stamp, "title": f"SAS eNews – {_human(stamp)}",
                     "summarized": stamp in seen, "has_page": page.exists(), "page": str(page),
                     "raw": str(DIR / f"{stamp}.raw.html"), "live": stamp == live})
    print(json.dumps({"issues": rows, "error": live_error, "url": URL}))


def cmd_status():
    req = sb._load_json(REGEN, {})
    print(json.dumps({"regen_pending": bool(req.get("id")) and not req.get("done"), "regen_id": req.get("id"),
                      "last_publish": sb._load_json(LAST_PUB, None)}))


def cmd_regen(stamp):
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", stamp or "") or not (DIR / f"{stamp}.raw.html").exists():
        print(json.dumps({"ok": False, "output": f"No archived eNews issue for {stamp}"}))
        return
    req = sb._load_json(REGEN, {})
    req.update(id=stamp, counter=int(req.get("counter", 0)) + 1, done=False, requested_at=time.time())
    REGEN.write_text(json.dumps(req))
    r = subprocess.run([sb.find_hermes(), "cron", "run", JOB_ID], capture_output=True, text=True)
    print(json.dumps({"ok": r.returncode == 0, "output": (r.stdout + r.stderr)[-400:]}))


if __name__ == "__main__":
    DIR.mkdir(parents=True, exist_ok=True)
    a = sys.argv[1:]
    cmd = a[0] if a else "fetch"
    if cmd == "latest-id": cmd_latest_id()
    elif cmd == "fetch": cmd_fetch()
    elif cmd == "publish": cmd_publish(a[1], a[2], a[3])
    elif cmd == "list": cmd_list()
    elif cmd == "status": cmd_status()
    elif cmd == "regen": cmd_regen(a[1] if len(a) > 1 else "")
    elif cmd == "notify": sb.notify(a[1], a[2])
    else: raise SystemExit(__doc__)
