# Web Tasks

Active `WEB-N` tasks and web-scoped `BUG-N` tasks live here.

# WEB-1: Rename Project To Her

Status: approved
Priority: P1
Owner: agent
Stream: web
Branch: web/WEB-1/rename-her
Created: 2026-05-07

## Goal

Rename the internal project/product identity from `meta`/`Meta` to `Her`.

## Context

The repository contains both internal project naming and external Meta Wearables DAT references. Internal product, package, storage, and documentation names should move to `Her`; external Meta/Facebook SDK names, keys, package URLs, and user-facing glasses integration labels should remain accurate.

## Scope

In scope:
- Update web app product copy, metadata, storage namespaces, and runtime paths.
- Update iOS/backend project names, bundle identifiers, display names, and task/docs references where they describe the internal project.
- Update repo docs and workflow maps to use Her naming.

Out of scope:
- Rename the GitHub repository/remote before review approval.
- Change external Meta Wearables DAT names, SDK URLs, Info.plist keys, or Facebook package identities.
- Commit, push, PR, archive, or mark done before human review.

## Implementation Plan

- [x] Inspect internal and external `meta`/`Meta` occurrences.
- [x] Rename internal web project identifiers and copy.
- [x] Rename internal iOS/backend identifiers and docs.
- [x] Run targeted verification and record results.

## Verification

- `pnpm lint`
- `pnpm test`
- `pnpm build`
- `python3 -m compileall her-ios/backend/app`
- `xcodebuild -project her-ios/frontend/ConversationSummarizer.xcodeproj -scheme ConversationSummarizer -destination 'generic/platform=iOS' -derivedDataPath her-ios/frontend/DerivedData CODE_SIGNING_ALLOWED=NO clean build`
- `rg -n "\[META-T|meta-ios|metaagent|meta\.app|Meta App|meta_credentials|mcp__meta_credentials|meta\.lang|meta\.exact|meta\.keys|meta-pulse|~/.meta|META_HOME|ensureMetaHome" -g '!app/.next/**' -g '!app/node_modules/**' -g '!her-ios/frontend/DerivedData/**' -g '!**/.venv/**' -g '!**/*.sqlite3'`

## Result

Renamed the internal project identity to Her across the web app, runtime namespaces, repo docs, iOS/backend folder path, iOS bundle/display/product names, AppIntent labels, backend package/title defaults, and browser workflow test labels.

Preserved external Meta Wearables DAT naming, SDK package references, Info.plist `MetaAppID`/`META_APP_ID` keys, and Ray-Ban Meta device copy/detection. The web database now uses `.data/her.db` and copies existing `.data/meta.db` into the new file on first startup when needed.

## Next

Human approved the implemented result. Next: commit, push, open draft PR, then wait for merge before archival.
