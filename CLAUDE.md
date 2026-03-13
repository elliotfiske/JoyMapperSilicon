# JoyMapperSilicon

## GitHub: Auth Switch for Personal Repo Operations

This repo (`elliotfiske/JoyMapperSilicon`) is owned by a personal GitHub account, but the active `gh` CLI session uses an Enterprise Managed User (`efiske_life360`). To run GitHub operations (create PRs, merge, etc.), temporarily switch accounts:

```bash
gh auth switch --user elliotfiske && <gh command>; gh auth switch --user efiske_life360
```

Note: `gh auth` state is global, so this will affect any other active agents while switched.
