"""Adds the permissions CelYah needs to the Android manifest created by `flutter create`."""
import re

PATH = "app_build/android/app/src/main/AndroidManifest.xml"
s = open(PATH, encoding="utf-8").read()

PERMS = """
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.RECORD_AUDIO"/>
    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30"/>
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation"/>
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30"/>
"""

INTENTS = """
        <intent>
            <action android:name="android.speech.RecognitionService"/>
        </intent>
        <intent>
            <action android:name="android.intent.action.TTS_SERVICE"/>
        </intent>
"""

if "RECORD_AUDIO" not in s:
    s = re.sub(r"(<manifest[^>]*>)", lambda m: m.group(1) + PERMS, s, count=1)

if "<queries>" in s:
    s = s.replace("<queries>", "<queries>" + INTENTS, 1)
else:
    s = s.replace("<application", "<queries>" + INTENTS + "    </queries>\n    <application", 1)

if "usesCleartextTraffic" not in s:
    s = s.replace("<application", '<application android:usesCleartextTraffic="true"', 1)

open(PATH, "w", encoding="utf-8").write(s)
print("manifest patched")
