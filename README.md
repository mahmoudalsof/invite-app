# invite-app

Digital invitations and door check-in for Saudi weddings and engagements (working name).

- `server/` Go service (API, guest pages, jobs)
- `api/` OpenAPI spec
- `design/` design tokens
- `ios/` SwiftUI app
- `android/` Kotlin app (later)

See `CLAUDE.md` for the approved stack, product rules, build order and current status.

## Local development

Needs Docker and Go (any Go 1.21+ downloads the pinned Go 1.27 toolchain on first use).

```bash
make db-up      # Postgres 18 in Docker Compose
make migrate    # apply migrations
make run        # server on :8080, try GET /healthz
```

`make help` lists every target.
