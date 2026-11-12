# SAS Sync

A small native macOS app for Singapore American School students that brings two things into one window:

- **HS Daily Bulletin → short, personalized summaries.** You get a "⭐ For you" section, new items at the top, and everything else folded away.
- **Toddle assignments → Google Tasks.** It syncs Toddle calendar tasks and reminder/due-date emails into a "School" task list.

<img src="Resources/icon_preview.png" width="96" alt="SAS Sync icon">

## Features

- **Assignments:** open tasks are grouped as Overdue, Today, Tomorrow, Next 7 days and Later. Use **Sync Now** to pull from Toddle, and check off a task to complete it in Google Tasks.
- **Bulletins:** browse the last 60 days, read each summary in the app, and **Regenerate** any day with your current settings.
- **Settings:** turn summary sections on or off, set item limits and the urgent-deadline window, add extra instructions, and edit an interests profile. You can also set the assignment look-ahead, choose notifications, and pause or resume each automatic job.
- **Notifications:** clickable macOS pop-ups with a custom icon.
- **Sign-in:** one Google sign-in covers everything. Gmail and Calendar access is read-only, and Tasks access is read/write.

## How it works

```
Gmail + Toddle calendar ──► backend/*.py ──► Hermes cron jobs ──► summary pages · Google Tasks · notifications
                                  ▲                                            │
                                  └──────── SAS Sync.app (SwiftUI) ◄───────────┘
```

| File | Purpose |
|---|---|
| `Sources/main.swift` | SwiftUI app; it calls `~/.hermes/scripts/sas_bulletin_cli.sh` and `sas_tasks_cli.sh` |
| `backend/sas_google.py` | Shared Google OAuth (one token) |
| `backend/sas_bulletin.py` | Fetches bulletins, tags sections NEW/REPEAT, renders HTML, handles regenerate requests |
| `backend/sas_tasks.py` | Syncs Toddle to the Google Tasks "School" list without duplicates, and handles completing tasks |
| `backend/cron-prompts.md` | The three [Hermes](https://hermes-agent.nousresearch.com) scheduled jobs |

## Requirements

- macOS 14+ and Xcode command-line tools (Swift)
- [Hermes Agent](https://hermes-agent.nousresearch.com) with the jobs in `backend/cron-prompts.md`
- Python with `google-auth-oauthlib`, `google-api-python-client` and `markdown`
- `brew install terminal-notifier`
- A Google Cloud OAuth "Desktop app" client with the Gmail, Calendar and Tasks APIs enabled, saved as `~/.hermes/google_client_secret.json`
- Toddle calendar subscribed in Google Calendar (with a calendar name containing "Toddle")

## Setup

```bash
cp backend/*.py backend/*.sh ~/.hermes/scripts/
chmod +x ~/.hermes/scripts/*.sh
./build.sh            # builds and installs ~/Applications/SAS Sync.app
```

Open the app and sign in with your school Google account. Put your own interests in `~/.hermes/sas_bulletins/profile.md` (Settings → Bulletin → Edit My Interests Profile).

## Privacy

Your tokens, OAuth client secret, profile, settings and generated summaries stay local under `~/.hermes` and are never committed.

## License

[MIT](LICENSE)
