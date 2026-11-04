# Applies permissions, Hebrew name and RTL to the native projects. Safe to run more than once.
import re
p='ios/App/App/Info.plist'; s=open(p,encoding='utf8').read()
add={
 'NSCameraUsageDescription':'<string>כדי לצלם תמונות וסרטונים מהחתונה ולשתף אותם עם החבורה.</string>',
 'NSMicrophoneUsageDescription':'<string>כדי להקליט קול בסרטונים שאתם מצלמים בחתונה.</string>',
 'NSPhotoLibraryUsageDescription':'<string>כדי לבחור תמונות וסרטונים מהגלריה ולהעלות אותם לאלבום החתונה.</string>',
 'NSPhotoLibraryAddUsageDescription':'<string>כדי לשמור בגלריה תמונות וסרטונים מאלבום החתונה.</string>',
 'ITSAppUsesNonExemptEncryption':'<false/>',
 'CFBundleLocalizations':'<array>\n\t\t<string>he</string>\n\t</array>',
}
for k,v in add.items():
    if f'<key>{k}</key>' not in s:
        s=s.replace('<dict>\n',f'<dict>\n\t<key>{k}</key>\n\t{v}\n',1)
s=re.sub(r'(<key>CFBundleDevelopmentRegion</key>\s*<string>)[^<]*(</string>)', r'\1he\2', s)
s=re.sub(r'(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)', r'\1שני צדדים\2', s)
open(p,'w',encoding='utf8').write(s)

p='android/app/src/main/AndroidManifest.xml'; s=open(p,encoding='utf8').read()
perms=['<uses-permission android:name="android.permission.CAMERA" />',
 '<uses-permission android:name="android.permission.RECORD_AUDIO" />',
 '<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />',
 '<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />',
 '<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32" />',
 '<uses-feature android:name="android.hardware.camera" android:required="false" />']
for x in perms:
    if x not in s: s=s.replace('<uses-permission android:name="android.permission.INTERNET" />','<uses-permission android:name="android.permission.INTERNET" />\n    '+x)
if 'supportsRtl' not in s: s=s.replace('<application','<application\n        android:supportsRtl="true"',1)
open(p,'w',encoding='utf8').write(s)

for p in ['android/app/src/main/res/values/strings.xml']:
    s=open(p,encoding='utf8').read()
    s=re.sub(r'(<string name="app_name">)[^<]*(</string>)', r'\1שני צדדים\2', s)
    s=re.sub(r'(<string name="title_activity_main">)[^<]*(</string>)', r'\1שני צדדים\2', s)
    open(p,'w',encoding='utf8').write(s)
print("native config applied")
