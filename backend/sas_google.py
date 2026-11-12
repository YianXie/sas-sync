"""Shared Google sign-in for SAS Sync (bulletin summaries + Toddle -> Google Tasks).

One token with the union of scopes:
  gmail.readonly    - read the HS Daily Bulletin and Toddle emails
  calendar.readonly - read the Toddle calendar feed
  tasks             - write assignments into the Google Tasks "School" list
"""
import json, sys
from pathlib import Path

HOME = Path.home() / ".hermes"
CLIENT = HOME / "google_client_secret.json"
TOKEN = HOME / "sas_google_token.json"
PENDING = HOME / "sas_google_pending.json"
SCOPES = [
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/calendar.readonly",
    "https://www.googleapis.com/auth/tasks",
]
REDIRECT = "http://localhost:1"
NET_ERRORS = ("TransportError", "ConnectionError", "NameResolution", "Timeout", "timed out", "ServerNotFound")


def is_network_error(e):
    s = f"{type(e).__name__} {e}"
    return any(x in s for x in NET_ERRORS)


def creds():
    from google.oauth2.credentials import Credentials
    from google.auth.transport.requests import Request
    c = Credentials.from_authorized_user_file(str(TOKEN), SCOPES)
    if not c.valid:
        c.refresh(Request())
        TOKEN.write_text(c.to_json())
    return c


_SVC = {}


def service(name, version):
    if name not in _SVC:
        from googleapiclient.discovery import build
        _SVC[name] = build(name, version, credentials=creds(), cache_discovery=False)
    return _SVC[name]


def auth_url():
    from google_auth_oauthlib.flow import Flow
    flow = Flow.from_client_secrets_file(str(CLIENT), scopes=SCOPES, redirect_uri=REDIRECT,
                                         autogenerate_code_verifier=True)
    url, state = flow.authorization_url(access_type="offline", prompt="consent")
    PENDING.write_text(json.dumps({"state": state, "verifier": flow.code_verifier}))
    print(url)


def auth_code(raw):
    from urllib.parse import urlparse, parse_qs
    from google_auth_oauthlib.flow import Flow
    p = json.loads(PENDING.read_text())
    code = raw
    if raw.startswith("http"):
        q = parse_qs(urlparse(raw).query)
        code = q["code"][0]
        if q.get("state", [p["state"]])[0] != p["state"]:
            sys.exit("ERROR: state mismatch - run auth-url again")
    flow = Flow.from_client_secrets_file(str(CLIENT), scopes=SCOPES, redirect_uri=REDIRECT,
                                         state=p["state"], code_verifier=p["verifier"])
    flow.fetch_token(code=code)
    TOKEN.write_text(flow.credentials.to_json())
    TOKEN.chmod(0o600)
    PENDING.unlink(missing_ok=True)
    print("OK: token saved")
