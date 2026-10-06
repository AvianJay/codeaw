# Review of master afc7265 (2026-10-06)

Reviewed `bfdd43b`, `2c8b21d`, `8a7c553`, `00e6d8d` and merge
`afc7265b6c1e995cad30cd21be3fdd532a9a182b` in a separate checkout.
No changes from that checkout were merged into the comparison build.

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
