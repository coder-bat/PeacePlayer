#!/usr/bin/env python3
"""Build/test on a newly created simulator, then delete only that simulator."""
import json
from pathlib import Path
import subprocess
import uuid


def output(*args):
    return subprocess.check_output(args, text=True)


def main():
    root = Path(__file__).resolve().parents[1]
    runtimes = json.loads(output("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    supported = [r for r in runtimes if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]
    if not supported:
        raise SystemExit("Install an iOS simulator runtime in the selected Xcode before testing.")
    runtime = max(supported, key=lambda r: tuple(int(x) for x in r["version"].split(".")))
    devices = json.loads(output("xcrun", "simctl", "list", "devicetypes", "--json"))["devicetypes"]
    phones = [d for d in devices if d.get("productFamily") == "iPhone"]
    # iPhone 16 is supported by both iOS 18 and newer installed runtimes.
    phone = next((d for d in phones if d["name"] == "iPhone 16"), phones[-1])
    simulator = output("xcrun", "simctl", "create", "PeacePlayerTests-" + uuid.uuid4().hex[:8],
                       phone["identifier"], runtime["identifier"]).strip()
    artifacts = root / ".test-artifacts"
    artifacts.mkdir(exist_ok=True)
    result = artifacts / ("ios-" + uuid.uuid4().hex[:8] + ".xcresult")
    try:
        subprocess.run(["xcodebuild", "test", "-project", str(root / "ios/YTAudioPlayer.xcodeproj"),
                        "-scheme", "YTAudioPlayer", "-destination", "platform=iOS Simulator,id=" + simulator,
                        "-derivedDataPath", str(artifacts / "DerivedData"), "-resultBundlePath", str(result),
                        "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=NO"], check=True)
    finally:
        subprocess.run(["xcrun", "simctl", "delete", simulator], check=True)


if __name__ == "__main__":
    main()
