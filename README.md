# SAS Bulletin

A small native macOS app that turns the Singapore American School **HS Daily Bulletin** email into a short, personalized summary — with a "⭐ For you" section, new items on top, and everything else folded away.

<img src="Resources/icon_preview.png" width="96" alt="SAS Bulletin icon">

## Features

- Browse the last 60 days of bulletins and read each summary in-app
- **Regenerate** any day's summary with your current settings
- Settings: toggle the ⭐ For you / 🆕 New today / folded sections, item limits, urgent-deadline window, extra instructions, and an editable interests profile
- Clickable macOS notifications with a custom icon when a new summary is ready
- Pause/resume the automatic weekday summaries; in-app Google sign-in (read-only Gmail)

## How it works

```
Gmail (read-only) ──► backend/sas_bulletin.py ──► Hermes cron job (LLM summary) ──► HTML page + notification
                                 ▲                                                           │
                                 └──────────── SAS Bulletin.app (SwiftUI control panel) ◄────┘
```

- `Sources/main.swift` — the SwiftUI app. It shells out to `~/.hermes/scripts/sas_bulletin_cli.sh`.
- `backend/` — Python fetcher/renderer plus wrapper scripts. It splits each bulletin into sections and tags them NEW / REPEAT against earlier bulletins.
- `backend/cron-prompt.md` — the summarization prompt used by the [Hermes](https://hermes-agent.nousresearch.com) scheduled job.

## Requirements

- macOS 14+, Xcode command-line tools (Swift)
- [Hermes Agent](https://hermes-agent.nousresearch.com) with a scheduled job using `backend/cron-prompt.md`
- Python with `google-auth-oauthlib`, `google-api-python-client`, `markdown`
- `brew install terminal-notifier`
- A Google Cloud OAuth "Desktop app" client (Gmail API enabled), saved as `~/.hermes/google_client_secret.json`

## Setup

```bash
cp backend/* ~/.hermes/scripts/
chmod +x ~/.hermes/scripts/*.sh
./build.sh            # builds and installs ~/Applications/SAS Bulletin.app
```

Open the app and sign in with your school Google account. Put your own interests in `~/.hermes/sas_bulletins/profile.md` (Settings → Edit My Interests Profile).

## Privacy

Gmail access is read-only. Tokens, the OAuth client secret, your profile and generated summaries all stay local under `~/.hermes` and are never committed.

## License

[MIT](LICENSE)
