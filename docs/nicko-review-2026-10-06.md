# Review of master afc7265 (2026-10-06)

Reviewed `bfdd43b`, `2c8b21d`, `8a7c553`, `00e6d8d` and merge
`afc7265b6c1e995cad30cd21be3fdd532a9a182b` in a separate checkout.
The findings below describe that pre-merge snapshot. The combined implementation
now keeps Nicko's Android Live Updates, file mentions, attachment menu, MCP tool
display and Windows updater fix, alongside concurrent iOS Live Activities and
the existing history, quota, receipt and upload-progress changes.

## Merge resolutions

- The Android tracker is isolated in `android_live_activity.dart` and only owns
  the native channel on Android. iOS retains the concurrent activity controller,
  shared attributes, extension target and APNs protocol. A platform routing test
  verifies that Android does not call the iOS channel API and vice versa.
- Both upload responses are supported: `sessionId` requests receive HTTP 201
  with the original block/hash; requests without it receive Nicko's HTTP 200
  file description. An unknown session never falls back to the other route.
- Both storage paths now use awaited bounded disk writes and clean partial
  files on failure. HTTP tests inject an asynchronous disk-full error while the
  sender remains open, verify HTTP 500 and cleanup, then check the same bridge
  still answers health and activity requests.
- Uploads support 512 MiB with native file streaming and browser Blob submission.
  The floating attachment menu retains sequential byte progress and waits for
  bridge acknowledgement before send. Compact file chips fit landscape.

Local combined checks: 145 bridge tests passed (7 skipped), TypeScript typecheck
passed, 196 Flutter tests passed (12 skipped), and Flutter analysis passed.

## Findings

1. **P1: upload write failures can terminate the whole bridge.**
   [uploads.ts lines 53–62](https://github.com/AvianJay/codeaw/blob/afc7265b6c1e995cad30cd21be3fdd532a9a182b/bridge/src/server/uploads.ts#L53-L62)
   creates a WriteStream without a persistent error handler. While receiving a
   slow request after a small successful `write`, an asynchronous ENOSPC/EACCES
   error has no listener; the surrounding async try/catch cannot catch that
   EventEmitter error. An isolated child process with an asynchronously failing
   Writable exited with code 1 and `Unhandled 'error' event` instead of returning
   an upload error. This can stop unrelated sessions. Use `pipeline` or attach
   stream error handling before writing, propagate it to the upload promise, and
   test a disk error while the request is still streaming.

2. **P2: the new upload endpoint breaks existing paired apps.**
   [http.ts lines 132–141](https://github.com/AvianJay/codeaw/blob/afc7265b6c1e995cad30cd21be3fdd532a9a182b/bridge/src/server/http.ts#L132-L141)
   changes the existing URL from HTTP 201 with `{name,path,size,sha256,block}` to
   HTTP 200 with `{path,uri,name,size,mimeType?}` without negotiation. The installed
   comparison iOS app requires 201 and uses `block`. Reproduction against the
   actual new HTTP handler wrote 24 bytes successfully but returned 200 without
   `block`, which the old app reports as a failed upload. The opposite mix also
   fails: the new app omits sessionId and the older bridge returns 400, while its
   friendly old-version message only handles 404. Retain the old response for
   requests with sessionId, version the endpoint, or negotiate capabilities.

## Requested feature differences

Master's iOS implementation uses one native activity and one selected session.
With several running sessions and no visible selected chat, `_pick()` returns
null. It requests `pushType: nil`, sets staleDate to 45 seconds, and uses a short
UIKit background task plus a 20-second in-process timer. This cannot deliver
changed commands/completion after iOS suspends the app. It adds Android live
updates and shows a chat title; those are useful additions, but do not meet the
requested multiple iOS sessions or sustained locked-screen updates.

The Windows `sc.exe` updater change correctly distinguishes Bun's truncated
1060 exit code from unrelated failures using the diagnostic. No actionable issue
was found in that change. MCP name parsing, file mentions and the attachment menu
were reviewed without a confirmed additional finding.

## Validation

- Master's `npm test`: 121 passed, 7 skipped; `npm run typecheck`: passed.
- [All-platform build](https://github.com/AvianJay/codeaw/actions/runs/37393545924):
  success, including unsigned iOS and Windows installer smoke tests.
- Isolated HTTP compatibility and Writable-error reproductions described above.
- No iPhone installation or APNs delivery was performed for master during review.
