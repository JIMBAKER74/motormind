# Development setup (macOS, Apple Silicon)

Written for this Mac on 2026-10-04: Apple M5 Pro, macOS 26.3, Homebrew installed, Android
SDK present at `~/Library/Android/sdk` (platform 37, no system images, no Java), no Xcode
(Command Line Tools only), no Flutter, Dart or FVM.

The repo pins Flutter in `.fvmrc`. Use that version; the `flutter_edge_ai_sqlite` package
needs 3.47 or newer and the rest need 3.44 or newer.

## 1. Flutter

Installed 2026-10-04: Flutter 3.47.6 (stable) at `~/flutter`, and a standalone Dart SDK via
Homebrew. `~/.zshrc` puts `~/flutter/bin` on the PATH (a backup of the previous file is at
`~/.zshrc.bak-2026-10-04`). Open a new terminal, then:

```bash
flutter --version
```

FVM is optional. `.fvmrc` pins 3.47.0 for anyone who uses it; the installed 3.47.6 is the
same minor version and is what CI will use.

## 2. Verify the pure-Dart packages first

These need only the Dart that ships inside Flutter. No device, no Xcode.

```bash
cd "/Users/sirisdev/Documents/personal work/demo-projects/motormind/edge_ai_demo/apps/motormind/packages/vehicle_finance" && dart pub get && dart test
```

```bash
cd "/Users/sirisdev/Documents/personal work/demo-projects/motormind/edge_ai_demo/apps/motormind/packages/advisor_core" && dart pub get && dart test
```

Both pass as of 2026-10-04 (31 and 27 tests).

## 3. Android

1. Install Android Studio (already present) and open **SDK Manager**. Install:
   - Android SDK Platform 35 or newer, plus **Android SDK Command-line Tools (latest)**.
   - **Android Emulator** and an **arm64-v8a** system image (Google APIs, API 35). On
     Apple Silicon only arm64 images run, and only arm64 can load the on-device LLM
     engine; x86_64 images will not run the model.
2. Java: Android Studio bundles a JDK. Point Flutter at it:

```bash
flutter config --jdk-dir "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
```

3. Accept licenses:

```bash
flutter doctor --android-licenses
```

4. Create an emulator (Device Manager, Pixel 8 Pro, API 35, arm64) with at least **6 GB
   RAM** so a 2.4 GB model fits with headroom.

   *Low-memory emulators (2026-10-18).* Android Studio's default "Medium Phone" device is
   configured with 2 GB of RAM (it reports about 4 GB total and 2 GB free). Motormind runs
   there, on the CPU, with the smallest context window it allows (4,096 tokens), and a
   first turn takes about a minute. It is a useful stand-in for a low-memory phone and a
   poor one for timing. For timing, use `motormind_pixel8` (8 GB) or a real phone.

Real device: enable developer options and USB debugging on the Samsung Fold 4, plug in,
`flutter devices`.

## 4. iOS

1. Install **Xcode** from the App Store (around 15 GB), open it once, accept the license,
   and install the iOS platform when prompted. Then:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -runFirstLaunch
```

2. CocoaPods, used by Flutter plugins:

```bash
brew install cocoapods
```

3. The iOS Simulator runs the model on CPU only (Metal has a 256 MB single-allocation
   cap in the simulator), so it is slow but works for UI. A physical iPhone needs an Apple
   Developer account for signing; the free personal team works for development installs
   with a seven-day expiry.

## 5. Check everything

```bash
flutter doctor -v
```

Everything except "Chrome" and "VS Code" should be green. Paste the output into the chat if
not.

## 6. The app

`apps/motormind` was generated on 2026-10-04 with
`flutter create --org com.sirisdevelopment --project-name motormind --platforms android,ios --empty`
and is a member of the root pub workspace. Resolve and test from the repo root:

```bash
cd "/Users/sirisdev/Documents/personal work/demo-projects/motormind/edge_ai_demo" && flutter pub get && flutter analyze apps/motormind
```

```bash
cd "/Users/sirisdev/Documents/personal work/demo-projects/motormind/edge_ai_demo/apps/motormind" && flutter test
```

Run on a device or arm64 emulator:

```bash
cd "/Users/sirisdev/Documents/personal work/demo-projects/motormind/edge_ai_demo/apps/motormind" && flutter run
```

Emulator GPU mode matters for the web pane. With `-gpu host` the Android WebView aborts the
whole app (Chromium: "Chrome runs only on top of OpenGL ES … VERSION =") as soon as a page
asks for WebGL, which Cars.com's human check does. Software GL avoids that at the cost of a
slower emulator (rendering and inference share the CPU):

```bash
emulator -avd motormind_pixel8 -no-boot-anim -no-audio -gpu swiftshader_indirect
```

Use `-gpu host` when the pane is not the point and speed is. A physical phone has neither
problem.

## 7. Models: no token needed

Both catalog models are `.litertlm` bundles from the public `litert-community` Hugging Face
organization, which is **not gated**:

| Model | Repo | File | Size |
|---|---|---|---|
| Gemma 4 E2B (default) | `litert-community/gemma-4-E2B-it-litert-lm` | `gemma-4-E2B-it.litertlm` | 2.59 GB |
| Qwen3 0.6B (light) | `litert-community/Qwen3-0.6B` | `Qwen3-0.6B.litertlm` | 0.61 GB |

The app downloads them itself (Models screen) with progress, retry and an Android
foreground service. A Hugging Face token is only needed for gated repos or a private mirror;
the key icon on the Models screen stores one in secure storage.

**Do not use `google/gemma-4-E2B`.** That repo is the raw training checkpoint
(`model.safetensors`, 10 GB) and cannot be loaded by LiteRT-LM. A copy of it was downloaded
to `~/.cache/huggingface/hub/models--google--gemma-4-E2B/` on 2026-10-04 and can be deleted.

To fetch a bundle on the Mac (for `adb push` to an emulator, or to seed a self-hosted
mirror), the `hf` CLI is installed via pipx:

```bash
hf download litert-community/gemma-4-E2B-it-litert-lm gemma-4-E2B-it.litertlm --local-dir ~/models/motormind
```

## 8. Analytics and the Firebase key

Firebase Analytics is wired in, and the project identifiers are supplied at build time, never committed. Copy `apps/motormind/firebase.env.example` to `firebase.env`, fill it from your Firebase project's app settings (API key, app id, sender id, project id), and build with `--dart-define-from-file=firebase.env`. Without that file the app runs with analytics as a no-op. The Android `google-services` Gradle plugin is not used; `firebase_core` is initialized from Dart with those values, so no `google-services.json` or `GoogleService-Info.plist` is needed. Why the key is treated this way is in the README under "Analytics and the Firebase key."

## Release signing (Android)

A release build signs with the debug key unless `apps/motormind/android/key.properties`
exists (it is git-ignored, as are `*.jks` and `*.keystore`):

```properties
storeFile=../keys/motormind-release.jks
storePassword=…
keyAlias=motormind
keyPassword=…
```

Create the keystore once with `keytool -genkey -v -keystore motormind-release.jks -keyalg RSA
-keysize 2048 -validity 10000 -alias motormind` and keep it outside the repository. A build
signed with the debug key is for local `flutter run --release` only.
