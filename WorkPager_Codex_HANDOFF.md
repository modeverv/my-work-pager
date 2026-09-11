# Work Pager for macOS — Codex Handoff

## 1. Purpose

Build a small native macOS app in Swift that acts as a **work attention pager**.

The user has a company Windows PC whose Slack client cannot be accessed from personal devices.  
The company PC's audio output is physically routed into an RME audio interface connected to the user's Mac.

The macOS app must:

1. Read a selected RME audio input device/channel.
2. Detect the known Slack notification sound in that input stream.
3. Only send alerts while the app is **ARMED**.
4. When detected, send a minimal notification through **ntfy** to the user's iPhone.
5. Never send Slack message contents, audio, screenshots, channel names, usernames, or other company data over the network.

The real requirement is not remote Slack access. It is only:

> "While away from the desk, tell me that I should return to the company PC."

---

## 2. Product concept

Normal usage:

```text
Company Windows PC
        |
        | analog / physical audio
        v
RME audio interface
        |
        | Core Audio
        v
macOS Work Pager app
        |
        | detect Slack notification sound
        v
ntfy
        |
        v
iPhone notification
"仕事PCを確認"
```

The app is manually started when work begins and quit when work ends.

ARM state can be controlled in two ways:

1. **Manual mode** — the user explicitly ARM/DISARMs.
2. **Auto Camera mode** — the Mac camera determines whether a person is present in front of the computer and automatically changes ARM state after configurable delays.

No menu-bar app is required.

---

## 3. Technology choices

Use:

- Swift
- SwiftUI
- macOS native application
- Core Audio / Audio HAL for audio device selection and capture
- Accelerate / vDSP where useful for DSP
- URLSession for ntfy HTTP requests
- UserDefaults for ordinary preferences
- Keychain for secret ntfy topic/token if appropriate

Target current macOS supported by recent Xcode.

Do not use Electron, Python, Node.js, or a browser wrapper.

---

## 4. UI requirements

Use a small normal macOS window.

### Main state

The most important control is a large ARM toggle/button.

Example:

```text
+----------------------------------+
| Work Pager                       |
|                                  |
|            DISARMED              |
|                                  |
|             [ ARM ]              |
|                                  |
| Input                            |
| Fireface UCX II                  |
| AN 5                             |
| ========----       -24 dBFS      |
|                                  |
| Notification Sound              |
| [ Learn ]     Match: 0.00        |
|                                  |
| ntfy                             |
| [ Send Test Notification ]       |
+----------------------------------+
```

When armed:

```text
+----------------------------------+
| Work Pager                       |
|                                  |
|              ARMED               |
|                                  |
|           [ DISARM ]             |
|                                  |
| Last detection: 09:42:18         |
| Last score: 0.96                  |
|                                  |
+----------------------------------+
```

Exact appearance is not important.  
Clarity is more important than visual polish.

### Settings needed in v0.1

- ARM mode selector: `Manual` / `Auto (Camera)`
- Audio input device selector
- Audio input channel selector
- Live input level meter
- Learn notification sound button
- Detection score display
- Detection threshold
- Cooldown seconds
- Camera selector
- Current camera presence state
- `Arm after absence` delay
- `Disarm after presence` delay
- Manual override / `Resume Auto`
- ntfy server URL
- ntfy topic
- Send test notification button

Defaults:

```text
ntfy server: https://ntfy.sh
notification title: Work Pager
notification body: 仕事PCを確認
cooldown: 30 seconds
```

Do not expose unnecessary options in v0.1.

---

## 5. Audio device handling

### Requirement

The app must be able to read a **specific hardware input and channel** from an RME interface without requiring the user to change the global macOS default input.

Expected examples:

```text
Device:
Fireface UCX II

Channel:
AN 1
AN 2
AN 3
...
```

Actual channel labels available from Core Audio should be used where possible.

### Implementation direction

Prefer Core Audio Audio HAL / AUHAL.

Typical approach:

- enumerate `AudioDeviceID`
- obtain device names
- enumerate input channels/streams
- instantiate HAL Output Audio Unit
- enable input
- disable output if unused
- set `kAudioOutputUnitProperty_CurrentDevice`
- obtain PCM buffers in the render callback
- convert to a known internal format if necessary

Internal processing format can be something simple such as:

```text
Float32
mono
48 kHz
```

Resample as needed.

The RME may expose many channels.  
The app must not assume stereo input only.

### Permissions

Include the required macOS microphone/audio-input usage description and handle permission denial gracefully.

---

## 6. ARM behavior

The app supports two ARM-control modes:

```text
ARM Mode
  ○ Manual
  ● Auto (Camera)
```

### 6.1 Manual mode

Manual mode behaves exactly as expected:

- `ARM` starts/ensures audio capture and detection.
- `DISARM` stops notification delivery and preferably stops active audio capture/DSP.
- The user explicitly controls state.

### 6.2 Auto Camera mode

Auto mode uses **camera input only** for presence detection.

Do **not** use:

- keyboard activity
- mouse activity
- Bluetooth presence
- screen lock state
- microphone activity
- network presence
- any other secondary presence signal

The desired behavior is intentionally simple and explainable.

Conceptually:

```text
person present continuously
        |
        | for configured duration
        v
      DISARM

person absent continuously
        |
        | for configured duration
        v
       ARM
```

Use two separately configurable delays:

```text
Arm after absence:      30 seconds
Disarm after presence:   5 seconds
```

These are suggested defaults only.

The UI must allow both values to be changed.

The purpose of the asymmetric defaults is:

- returning to the desk should DISARM quickly
- briefly standing up or moving out of frame should not immediately ARM

### 6.3 Hysteresis / debounce rules

Presence state must be stable for the configured delay before changing ARM state.

Examples:

```text
person disappears for 12 sec
Arm after absence = 30 sec
=> remain DISARMED

person disappears for 31 sec
=> ARM
```

Similarly:

```text
person appears for 2 sec
Disarm after presence = 5 sec
=> remain ARMED

person appears for 5+ sec
=> DISARM
```

Reset the corresponding timer if the raw presence state changes before the threshold is reached.

### 6.4 Manual override while Auto mode is active

Manual override is required.

If Auto Camera mode is active and the user manually changes ARM state, automatic camera control must pause rather than immediately undoing the user's action.

Example:

```text
AUTO says: DISARMED
user presses ARM
        |
        v
AUTO OVERRIDE
STATE: ARMED
```

The UI should clearly show something equivalent to:

```text
AUTO: OVERRIDDEN
STATE: ARMED

[ Resume Auto ]
```

Until `Resume Auto` is pressed:

- camera frames may continue to be processed for status display if desired
- camera presence must **not** change ARM state

When `Resume Auto` is pressed:

1. clear the override
2. restart the presence/absence timing window
3. allow Auto Camera mode to control ARM state again

This rule prevents the system from fighting the user's explicit action.

### 6.5 Runtime behavior by ARM state

#### DISARMED

When DISARMED:

- do not send ntfy alerts
- preferably stop active audio capture / DSP to reduce unnecessary work
- camera presence detection may continue if Auto Camera mode is enabled
- UI remains usable
- settings remain editable

#### ARMED

When ARMED:

1. start/ensure audio capture
2. detect Slack notification sound
3. if match score exceeds threshold:
   - check cooldown
   - send ntfy notification
   - update last detection timestamp
   - show last match score
4. continue monitoring


## 6.6 Camera presence detection implementation

Prefer native Apple frameworks:

- AVFoundation for camera capture
- Vision for person detection

Do not introduce OpenCV unless native frameworks prove insufficient.

Suggested pipeline:

```text
AVCaptureSession
      |
      v
camera frame
      |
      v
Vision person detection
      |
      v
personPresent: Bool
      |
      v
presence / absence timers
      |
      v
ARM state machine
```

The presence detector does **not** need video-rate analysis.

For desk-presence detection, approximately:

```text
1–2 frames per second
```

is sufficient unless testing proves otherwise.

Avoid unnecessary CPU/GPU use.

### Privacy requirement

Camera images must remain local and ephemeral.

Required behavior:

```text
camera frame
 -> local Vision processing
 -> Bool / confidence
 -> discard frame
```

Do not:

- save frames
- record video
- upload images
- transmit camera imagery
- send images to ntfy
- keep a history of camera frames

Only derived state such as:

```text
personPresent = true
```

may be retained.

### Camera UI

At minimum expose:

```text
Camera:
[ FaceTime HD Camera ▼ ]

Presence:
● PRESENT
```

or:

```text
Presence:
○ ABSENT
```

Also show enough state to debug hysteresis, for example:

```text
Absent for: 18 / 30 sec
```

This countdown/status is useful during development and may remain in the settings UI.

If no camera is available or permission is denied:

- do not crash
- clearly show camera unavailable
- fall back to manual ARM control
- do not silently change ARM state



## 7. Notification-sound learning

The app needs a `Learn` workflow.

### Goal

Record the real signal arriving at the selected RME input and save it as the reference template.

### Development workflow

During development, the user has a private Slack installation on the Mac and can generate the normal Slack notification sound repeatedly.

This can be used to develop and tune the detector.

The final production template should be learnable using the actual path:

```text
Company PC
 -> physical audio output
 -> RME input
 -> Mac
```

because Windows/DAC/ADC/routing may slightly alter the waveform.

### Learn UX

When `Learn` is pressed:

1. show an instruction such as:
   `Slackの通知音を1回鳴らしてください`
2. monitor the selected input
3. detect the next significant short sound event
4. capture a short region around it
5. normalize/process it
6. store it locally as the reference template
7. show success/failure

Do not require the user to manually locate a WAV file.

### Storage

Store the learned reference locally in the app's Application Support directory.

Do not upload the reference audio anywhere.

---



## 7.1 Development-only Slack sample source via BlackHole

During development, the target Slack notification sound does not need to come from the company Windows PC every time.

The user's private Slack client running on the Mac can be used as a repeatable test-signal generator.

A convenient development path is:

```text
Private Slack on Mac
        |
        | macOS audio output
        v
BlackHole virtual audio device
        |
        | loopback
        v
Work Pager
```

Use **BlackHole** only as a development/test input path.

This allows the developer to:

- generate the standard Slack notification sound repeatedly
- capture clean reference samples
- tune gate thresholds
- tune correlation/spectral matching
- run regression tests without involving the company PC
- reproduce test conditions quickly

A Multi-Output Device or Aggregate Device may be used if the developer wants to hear the Slack sound locally while also routing it into BlackHole.

Example development routing:

```text
Private Slack
    |
    v
Multi-Output Device
    |\
    | \--> normal Mac output / RME for monitoring
    |
    +----> BlackHole
              |
              v
          Work Pager
```

The application must therefore work with ordinary Core Audio devices in addition to RME hardware.  
Do not hardcode RME-specific device names or assumptions.

The final production verification must still use the real signal path:

```text
Company Windows PC
 -> physical audio output
 -> RME input
 -> Work Pager
```

because the Windows audio stack, DAC/ADC path, gain, sample-rate conversion, and physical routing may alter the waveform enough to require a final Learn operation or threshold adjustment.

BlackHole is a **development aid only** and is not required for the production workflow.


## 8. Sound detection algorithm

Do not use machine learning in v0.1.

The input conditions are favorable:

- signal comes electrically through RME, not through a room microphone
- Slack notification sound is fixed and short
- the path is mostly stable
- only one known target sound initially

Start simple.

### Suggested pipeline

```text
PCM input
  |
  v
mono conversion
  |
  v
ring buffer
  |
  v
RMS / peak gate
  |
  v
candidate window extraction
  |
  v
normalization
  |
  v
template comparison
  |
  v
match score 0.0 ... 1.0
```

### First comparison implementation

Try normalized cross-correlation first.

Use Accelerate/vDSP if convenient.

If direct time-domain matching proves too sensitive to the Windows -> analog -> RME path, then try:

1. short-time FFT / magnitude spectrum
2. normalized spectral comparison
3. simple log-magnitude spectrogram comparison

Do not jump to ML unless simple signal processing demonstrably fails.

### Useful diagnostics during development

Provide debug information such as:

```text
current RMS
candidate detected
candidate duration
match score
threshold
last successful match
```

A lightweight debug log pane is acceptable in development builds, but the final v0.1 UI should remain simple.

---

## 9. False-positive handling

Primary controls:

### Energy gate

Do not run expensive matching continuously on silence.

### Match threshold

Configurable.

Initial suggested default:

```text
0.90
```

Do not assume this value is correct; tune experimentally.

### Cooldown

After a successful notification, suppress additional successful notifications for:

```text
30 seconds
```

Default should be configurable.

Purpose:

- avoid duplicate alerts
- avoid bursts of several Slack notifications producing many iPhone pushes
- reduce ntfy usage

---

## 10. ntfy integration

### v0.1 publish behavior

Use HTTP POST via `URLSession`.

Default endpoint:

```text
https://ntfy.sh/<topic>
```

Payload must contain no company information.

Example:

```text
Title: Work Pager
Body: 仕事PCを確認
```

The remote service must never receive:

- Slack message text
- sender
- Slack channel
- timestamps from Slack itself
- screenshots
- audio
- learned notification sample
- company name
- PC contents

Only the attention event is sent.

### Topic

Use a long random unguessable topic name.

Example form:

```text
work-pager-<long-random-secret>
```

Do not hardcode a real topic in source control.

Store it locally.

If treated as a secret, prefer Keychain.

### Test button

`Send Test Notification` should immediately send the same ntfy alert without requiring audio detection.

This is required for troubleshooting.

### Failure behavior

Network errors must not crash the app.

Display a small status such as:

```text
Last notification: Success
```

or:

```text
Last notification: Failed - timeout
```

Do not endlessly retry in v0.1.

---

## 11. State model

Suggested conceptual model:

```text
AppState
  armed: Bool
  armMode: manual | autoCamera
  autoOverrideActive: Bool

PresenceSettings
  cameraID
  armAfterAbsenceSeconds
  disarmAfterPresenceSeconds

PresenceRuntime
  personPresent: Bool
  stableStateDuration
  cameraAvailable: Bool

AudioSettings
  deviceID
  channelIndex

DetectorSettings
  threshold
  cooldownSeconds
  templateURL

NtfySettings
  serverURL
  topic

RuntimeStatus
  inputLevelDB
  currentMatchScore
  lastDetectionDate
  lastNotificationResult
```

Persistence:

- ordinary settings -> UserDefaults
- sensitive topic/token -> Keychain if implemented
- learned audio template -> Application Support

---

## 12. Suggested source structure

One possible layout:

```text
WorkPager/
├── WorkPagerApp.swift
├── UI/
│   ├── ContentView.swift
│   ├── ArmView.swift
│   └── SettingsView.swift
├── Audio/
│   ├── AudioDeviceManager.swift
│   ├── AudioCaptureEngine.swift
│   ├── RingBuffer.swift
│   ├── SoundLearner.swift
│   └── SoundDetector.swift
├── Presence/
│   ├── CameraCaptureManager.swift
│   ├── PersonPresenceDetector.swift
│   └── AutoArmController.swift
├── Notification/
│   └── NtfyClient.swift
├── Model/
│   ├── AppState.swift
│   └── Settings.swift
├── Storage/
│   ├── PreferencesStore.swift
│   └── KeychainStore.swift
└── DSP/
    └── SignalMatcher.swift
```

Exact names may change if a cleaner design emerges.

Keep v0.1 small.  
Do not create abstractions that are not yet needed.

---

## 13. Development sequence

Implement in this order.

### Phase 1 — Audio visibility

Goal:

- app launches
- lists Core Audio input devices
- selects RME
- selects one channel
- shows a live level meter

No detector yet.

### Phase 2 — Record/Learn

Goal:

- Learn button captures a short notification sample
- saves it locally
- can replay/analyze the captured data during development
- verify capture using the private Mac Slack client routed through BlackHole

### Phase 3 — Offline matching

Goal:

- generate Slack notification repeatedly using the private Slack client
- route the notification audio through BlackHole as a repeatable loopback test source
- capture candidate signals
- calculate and display match scores
- tune normalization/windowing/threshold

### Phase 4 — Live detection

Goal:

- while ARMED, live Slack notification produces a reliable hit
- unrelated audio does not normally trigger

### Phase 5 — ntfy

Goal:

- Send Test works
- live detection sends iPhone notification
- cooldown works

### Phase 6 — Auto Camera ARM

Goal:

- camera can be selected
- person presence can be detected locally
- `Arm after absence` delay works
- `Disarm after presence` delay works
- manual override pauses automatic state changes
- `Resume Auto` restores automatic control
- camera frames are not stored

### Phase 7 — Production path verification

Switch the audio source to the real path:

```text
Company PC
 -> physical audio
 -> RME
 -> app
```

Run Learn once using the actual company-PC Slack notification sound.

Tune threshold if required.

---

## 14. v0.1 acceptance criteria

v0.1 is complete when all of these are true:

- [ ] Native Swift/SwiftUI macOS app builds successfully.
- [ ] App uses a normal window, not a menu-bar-only UI.
- [ ] RME input device can be selected.
- [ ] A specific RME input channel can be selected.
- [ ] Live signal level is visible.
- [ ] User can Learn a notification sound from the selected input.
- [ ] Learned template survives app restart.
- [ ] ARM/DISARM works.
- [ ] Manual ARM mode works.
- [ ] Auto Camera mode works.
- [ ] Camera can be selected.
- [ ] Presence / absence state is visible.
- [ ] `Arm after absence` delay is configurable and works.
- [ ] `Disarm after presence` delay is configurable and works.
- [ ] Manual override prevents Auto Camera from changing ARM state.
- [ ] `Resume Auto` restores camera-controlled ARM state.
- [ ] Camera frames are processed locally and are not saved or transmitted.
- [ ] Slack notification sound is detected reliably.
- [ ] Ordinary unrelated audio has a low false-positive rate.
- [ ] Detection score is visible.
- [ ] Cooldown prevents repeated pushes.
- [ ] ntfy test notification reaches iPhone.
- [ ] Real detected notification reaches iPhone.
- [ ] Notification content contains only a generic message such as `仕事PCを確認`.
- [ ] No audio or Slack content is transmitted to ntfy.
- [ ] Network failure does not crash the app.

---

## 15. Explicit non-goals for v0.1

Do NOT implement:

- menu bar integration
- launch-at-login
- Apple Push Notification service directly
- custom iPhone app
- ESP32 support
- MQTT
- Alexa integration
- Slack API
- Slack message parsing
- OCR
- screen capture
- company-PC software
- multiple target notification sounds
- machine-learning classification
- keyboard/mouse based presence detection
- Bluetooth/device-proximity presence detection
- multi-sensor presence fusion
- camera recording or image upload
- cloud audio processing
- remote desktop/KVM functionality

These can be considered later only if the minimal tool proves insufficient.

---

## 16. Privacy / data-boundary requirement

This is a hard design constraint.

The app may observe audio locally because the company PC's physical audio is connected to the RME.

However, after detection, the only information allowed to leave the Mac is an abstract attention event.

Conceptually:

```text
audio
  -> local pattern recognition
  -> boolean event
  -> generic push notification
```

Not:

```text
audio
  -> cloud
```

and not:

```text
Slack content
  -> personal device
```

The learned template must remain local.

---

## 17. Useful implementation notes

- Prefer stable, explicit audio-device identification rather than relying only on display names.
- RME devices may expose many channels; handle channel counts dynamically.
- Avoid blocking the real-time audio callback.
- Copy/minimize data in the audio callback and perform matching on a worker queue.
- Avoid allocations in the real-time callback where practical.
- UI updates must occur on the main actor.
- Network calls must never run in the audio callback.
- Use a ring buffer so the app can capture a little audio before the gate threshold crossing.
- A learned template should be normalized to reduce dependence on PC volume.
- If Windows volume changes significantly, amplitude normalization should prevent most issues.
- Keep enough instrumentation to tune detection before optimizing prematurely.

---

## 18. Expected final user workflow

### Start of work

1. Launch `Work Pager`.
2. Confirm RME/input status.
3. Select either:
   - `Manual`
   - `Auto (Camera)`

For normal daily use, `Auto (Camera)` is the intended convenience mode.

### While sitting at the desk in Auto mode

```text
camera sees person
      |
      | stable for configured delay
      v
DISARMED
```

No notifications are forwarded.

### Leaving the desk

The user simply gets up and leaves.

```text
camera sees no person
      |
      | e.g. 30 seconds
      v
ARMED
```

No button press is required.

### Slack notification arrives while away

1. Company Slack plays its normal notification sound.
2. Company PC sends audio physically to RME.
3. Work Pager recognizes the sound.
4. Work Pager sends a generic ntfy event.
5. iPhone vibrates/alerts:
   `仕事PCを確認`
6. User returns to the company PC and reads Slack there.

### Returning to the desk

```text
camera sees person
      |
      | e.g. 5 seconds
      v
DISARMED
```

The user does not need to manually DISARM.

### Manual override

At any time the user may manually change ARM state.

When this happens:

```text
AUTO: OVERRIDDEN
```

Camera presence must not change ARM state until the user selects:

```text
Resume Auto
```

### End of work

1. Quit the app.

This is the intended complete first product, not a later optional feature.

