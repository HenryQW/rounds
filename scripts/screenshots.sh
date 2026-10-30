#!/bin/sh
# The README picture: the demo session window (Sources/Rounds/Demo.swift) in light, of the window only, to
# website/public/screenshots/window-light.png. The docs site has no screenshots (the home page demo shows the app). Run scripts/bundle.sh first. It sends no keys or pointer events,
# but windows show and take focus, so it waits until the user is idle for 20 s. The installed app has the same global
# shortcut, so it is quit for the run and opened again at the end.
set -e
cd "$(dirname "$0")/.."
APP=build/Rounds.app/Contents/MacOS/Rounds
OUT=website/public/screenshots
TMP=$(mktemp -d)
mkdir -p "$OUT"

# Prints the id of the largest normal on-screen window of a process.
cat > "$TMP/window-id.swift" <<'EOF'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String: Any]]
let ids = windows.filter { $0[kCGWindowOwnerPID as String] as? Int == pid && ($0[kCGWindowLayer as String] as? Int ?? 0) == 0 }
    .map { w -> (Int, Double) in
        let b = w[kCGWindowBounds as String] as! [String: Double]
        return (w[kCGWindowNumber as String] as! Int, b["Width"]! * b["Height"]!)
    }
guard let best = ids.max(by: { $0.1 < $1.1 }) else { exit(1) }
print(best.0)
EOF
swiftc -o "$TMP/window-id" "$TMP/window-id.swift" 2>/dev/null

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ { print int($NF / 1000000000); exit }'; }
until [ "$(idle)" -ge 20 ]; do sleep 2; done

RUNNING=$(pgrep -x Rounds >/dev/null && echo 1 || echo 0)
cleanup() {
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
    rm -rf "$TMP"
    if [ "$RUNNING" = 1 ]; then open "/Applications/Rounds.app"; fi
}
trap cleanup EXIT
if [ "$RUNNING" = 1 ]; then pkill -x Rounds; sleep 1; fi

for scene in window; do
    for appearance in light; do
        "$APP" --demo --demo-scene "$scene" --demo-appearance "$appearance" >/dev/null 2>&1 &
        pid=$!
        tries=0
        until "$TMP/window-id" "$pid" >/dev/null; do
            tries=$((tries + 1))
            if [ $tries -gt 40 ]; then echo "no window for $scene ($appearance)" >&2; kill "$pid"; exit 1; fi
            sleep 0.25
        done
        # The slide and the first frames of the glasses.
        sleep 1.5
        screencapture -x -o -l "$("$TMP/window-id" "$pid")" "$OUT/$scene-$appearance.png"
        kill "$pid"
        wait "$pid" 2>/dev/null || true
        echo "$OUT/$scene-$appearance.png"
    done
done
