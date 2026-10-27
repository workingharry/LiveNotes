# LiveNotes 🎙️📚

> **Native macOS Real-Time Speech Recognition, Academic Lecture & Meeting Summarizer with AI Copilot.**

![macOS 13.0+](https://img.shields.io/badge/macOS-13.0%2B-blue?logo=apple)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange?logo=swift)
![License MIT](https://img.shields.io/badge/License-MIT-green)

LiveNotes is a high-performance, native macOS application designed for university students, researchers, and professionals attending lectures and meetings. It continuously captures audio, transcribes speech using Apple's on-device Speech framework with CoreAudio acoustic AGC processing, and generates structured, real-time notes and exam insights using OpenRouter AI.

---

## ✨ Features

- **🎙️ CoreAudio Adaptive AGC & Soft Limiter**:
  - Dynamically amplifies far-field and low-volume voices while protecting against clipping distortion.
  - Native single-channel audio conversion with zero buffer starvation.

- **⚡ Zero-Drift CJK Delta Slicing**:
  - Continuous streaming transcript alignment with CJK punctuation normalization.
  - Eliminates duplicate loops and partial phrase repetitions.

- **🤖 Dual AI Note-Taking Modes**:
  - **Student Lecture Mode**: Focuses on core theoretical concepts, professor exam emphasis, technical formulas, terminology definitions, and assignments/review checklists.
  - **General Meeting Mode**: Real-time rolling recap, confirmed decisions, action item assignments (owner + due date), and unresolved discussion points.

- **💬 Real-Time Academic Copilot**:
  - Interactive Q&A sidebar with the classroom or meeting context.
  - Allows students to query exam tips, clarify complex concepts, or review past lecture segments on demand.

- **📝 Notes & Vault Integration**:
  - One-click direct synchronization to **Obsidian** vaults (`obsidian://new`).
  - Formatted clipboard export ready for **Notion** databases and meeting logs.
  - Full local session history store with instant search and playback.

---

## 🚀 Installation & Getting Started

### 1. Download DMG
Download the latest `LiveNotes.dmg` from the [GitHub Releases](https://github.com/workingharry/LiveNotes/releases) page. Open the DMG and drag **LiveNotes.app** into your **Applications** folder.

### 2. Configure OpenRouter API Key
1. Launch **LiveNotes**.
2. Open **Settings** (⚙️) from the top-right toolbar.
3. Enter your [OpenRouter API Key](https://openrouter.ai/keys) (`sk-or-v1-...`) and select your preferred model (supports `openrouter/free`, `google/gemini-2.0-flash`, `anthropic/claude-3.5-sonnet`, and any custom model).
4. Alternatively, you can set the `OPENROUTER_API_KEY` environment variable in your shell.

---

## 🛠️ Building from Source

### Prerequisites
- macOS 13.0 (Ventura) or newer
- Xcode 15+ / Command Line Tools (Swift 5.9+)

### Build & Run
```bash
# Clone the repository
git clone https://github.com/workingharry/LiveNotes.git
cd LiveNotes

# Run unit tests (53 tests)
swift test

# Build and run
swift run LiveNotes
```

### Build Release DMG
```bash
./build_dmg.sh
```
The output disk image will be generated at `./LiveNotes.dmg`.

---

## 🔒 Security & Privacy

- **Microphone and Speech Recognition**: Uses Apple's native APIs (`AVAudioEngine`, `SFSpeechRecognizer`). No audio is ever recorded or uploaded without explicit user permission.
- **Zero Embedded Secrets**: API keys are securely stored in macOS User Defaults / Keychain and are never bundled into binaries or committed to source control.
- **Local Data Persistence**: Session transcripts and Markdown summaries are stored locally in `~/Documents/LiveNotes/`.

---

## 📄 License

MIT License. See [LICENSE](LICENSE) for details.
