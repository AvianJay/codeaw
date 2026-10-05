# iOS Live Activities (comparison branch)

This implementation adds iOS 16.2+ Lock Screen Live Activities and compact,
minimal and expanded Dynamic Island presentations. Dynamic Island requires a
device that has it; other supported iPhones show the Lock Screen presentation.
Android Live Progress is outside this change.

An opened chat's running turn starts an activity while the app is foregrounded.
The view shows the working-directory project name, agent, elapsed time, current
command or a short excerpt of an agent-provided thought/progress summary.
It never calls another model to invent a summary or requests hidden reasoning.
Waiting for approval is orange, completion green, error red, active work cyan,
and stale content gray. Tapping opens that session. Completion freezes the
timer and retains the final Lock Screen card for 60 seconds.

The app tracks opened chats, including when leaving the chat for settings, and
supports at most four concurrent activities. Closing the app screen does not
stop an AI turn. User-dismissed activities are not restarted for the same turn.
Switching computers, disabling the feature, or deleting a session removes its
activities. Settings persist the feature and project/detail visibility switches.
Hiding details redacts project names as well as commands and summary excerpts.

## Background updates

The timer is rendered by iOS and keeps ticking without app execution. Command,
summary, approval and completion updates use the connected app, or optional
ActivityKit APNs pushes from the PC. An ordinary WebSocket does not keep an iOS
app running after suspension. Without APNs, the last content becomes stale
after two minutes and says to open Codeaw to synchronize. While foregrounded,
the app refreshes every 60 seconds so a long, quiet command does not falsely
become stale. APNs update coalescing is 15 seconds, with approval/end updates
sent sooner; a 60-second bridge heartbeat maintains freshness. Apple's own
delivery budget and network conditions can delay updates.

The app must have started the activity before suspension. This change does not
remotely start new activities for chats never opened on the phone. APNs
subscriptions survive a phone WebSocket disconnect, expire after eight hours,
and re-register on resume/reconnect. A bridge restart requires a phone reconnect
to register its tokens again. Revoking a paired device stops subsequent pushes.

Configure on the PC only; the phone never receives the APNs private key:

```yaml
notifications:
  liveActivity:
    teamId: ABCDE12345
    keyId: 12345ABCDE
    privateKeyPath: 'C:\Users\you\.codeaw\AuthKey_12345ABCDE.p8'
    bundleId: tw.avianjay.codeaw
    environment: production # sandbox for a development-signed app
    includeDetails: true
```

The `.p8` must be an Apple APNs EC P-256 authentication key for the signing team.
`bundleId` must match the installed app's actual identifier and push-enabled
provisioning profile. `includeDetails` defaults to false: project names,
commands and excerpts pass through Apple's APNs service only when both this
setting and the phone's detail switch are enabled. Keys, APNs push tokens and
conversation transcripts are not logged or returned in info responses.
Subscriptions are bound to the authenticated paired device.

Restart the bridge after configuring APNs; announce it before stopping any
running bridge/turn. Settings show whether the PC has a usable key and whether
the phone has actually registered a token. A configured server alone does not
prove the phone has valid push signing or has received an APNs update.

## iOS build / signing

The unsigned IPA embeds `PlugIns/CodeawLiveActivity.appex` with the same build
number as Runner. The normal IPA keeps existing signing requirements and does
not force an APNs entitlement onto profiles that lack it. For local Live
Activities, re-sign and install the app **and its extension**; do not remove
extensions in the installer. Free signing may consume an additional App ID.

For APNs, use a registered App ID with Push Notifications and a matching
provisioning profile. `Runner/Runner-Push.entitlements` is supplied for signed
Xcode builds. The Runner-only `CODEAW_CODE_SIGN_ENTITLEMENTS` build variable can
be overridden to that path with `CODEAW_APNS_ENVIRONMENT=production` or
`development`. The extension's provisioning/signing must also be valid.
LCSign imports/signs/installs the IPA; APNs still requires a certificate/profile
that supports Push Notifications and retention of the widget extension.
Launching Codeaw as a LiveContainer guest cannot register the guest extension;
use a normal installed app for this feature.

References: [Apple ActivityKit](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities),
[ActivityKit push requirements](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications),
[APNs provider tokens](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns),
[LiveContainer extension limitations](https://github.com/LiveContainer/LiveContainer#limitations).

## Verification

Automated coverage checks streamed thought/tool folding, native turn isolation,
Unicode bounds, awaiting approval, cancellation/completion/error, current-turn
snapshots to unattached phones, APNs JWT signature/payload/privacy, device
ownership/revocation, retries, token rotation/reconnect, host changes and the
persisted feature switches. The scroll-to-bottom widget is tested while new
messages arrive without disturbing the reading position.

`bridge/scripts/live-activity-real-e2e.ts` exercises real Codex, `gpt-6-luna` /
`low`, against an isolated updated bridge by default. `--installed` instead
tests the already-running installed bridge through a temporary paired device,
which is revoked afterward; it does not restart the bridge. The test verifies
the command, project, turn timestamps, completion and reconnect for an
unattached watcher. Optional `--desktop-session codex:<id>` must identify an
idle dedicated chat that is open in Codex desktop. The primary work chat is
not changed. If ACP's bundled CLI does not list the requested model, set
`agents.codex.env.CODEX_PATH` to a compatible installed Codex executable and
reload the bridge before testing; setting it only in the test process does not
affect an already-running bridge.
Real APNs delivery has not been tested without a phone's token and matching
Apple credentials; a transport fixture is not a substitute for that test.

The macOS CI job compiles Swift and verifies the actual embedded extension's
bundle identifier, executable, support flag and version in the built app.
Comparison-branch dispatches produce downloadable artifacts and do not publish
over the shared nightly release.

On iPhone verify:

1. Start a long command in an opened chat; check project, readable status and
   continuing timer on the Lock Screen and all Dynamic Island presentations.
2. Tap the activity to reopen the right chat. Check completion/approval colors,
   frozen final time and removal after completion or disabling the setting.
3. Hide details and confirm project/command/summary are redacted. Dismiss an
   activity and confirm it stays dismissed for that turn.
4. Without APNs, lock for over two minutes and confirm the stale label; reopen
   and confirm recovery. With valid APNs signing/config, confirm a **different
   command and completion arrive while locked**, then test a phone reconnect.
5. Scroll up during streaming, tap “捲到最底”, and check portrait/landscape plus
   the keyboard. The button sits inside the chat area above the composer.
