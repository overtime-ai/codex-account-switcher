# Overtime fork

This fork of [liuzhao1225/codex-account-switcher](https://github.com/liuzhao1225/codex-account-switcher) removes application update behavior. The original MIT license and attribution remain in place.

- macOS has no Sparkle dependency, updater object, update UI, update feed, or embedded update verification key.
- Windows has no update HTTP client, startup check, hourly timer, update preferences, or download-page launcher.
- Release packaging and GitHub Pages no longer generate or publish update feeds.
- Existing update preferences cannot reactivate checks because the implementation is removed.
- Account authentication, switching, and usage refresh through the installed Codex runtime remain available. This is not an offline build of Codex.
- Codex Desktop stores projects, SSH host preferences and sidebar state per signed-in account, in `.codex-global-state.json` keys suffixed with an owner hash, and records the last owner in `electron-renderer-content-owner`. Whenever Desktop is closed (when it quits, at switcher startup, and during a switch), the switcher moves the last owner's keys to the account in `auth.json`, so every account loads one shared state. macOS only. Keep the switcher running at login.

Build from this fork using the instructions in the root README. Updates require a new build or manually installing a release from `overtime-ai`. Upstream packages do not include these changes.

No signed release is created by this change. The inherited release workflow requires the fork's own signing/notarization secrets before producing signed Mac packages. The local packaging script supports ad-hoc signing for local builds.

Historical design documents and the inherited product website describe upstream behavior. This document and the root README describe the fork's update policy. When importing upstream changes, check that no updater dependencies, timers, networking, UI, or packaging/feed configuration return.
