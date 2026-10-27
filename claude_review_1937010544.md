BUNDLE_ID=<填入 LiveNotes 的 CFBundleIdentifier>

# 1. 重置權限並啟動
tccutil reset Microphone "$BUNDLE_ID"
open LiveNotesMacApp/LiveNotes.app

# 2. 另開終端機觀察 CoreAudio 日誌
log stream --predicate 'process == "coreaudiod" OR subsystem == "com.apple.coreaudio" OR process == "LiveNotes"' --info

# 3. 操作：先拒絕麥克風 → 到系統設定改為允許（不要重啟 App）→ 再按 Start Listening