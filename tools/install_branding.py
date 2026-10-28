from pathlib import Path
import shutil
from PIL import Image
src=Path('assets/branding/celyah_launcher_1024.png')
res=Path('app_build/android/app/src/main/res')
for density,px in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
    folder=res/f'mipmap-{density}'
    folder.mkdir(parents=True,exist_ok=True)
    Image.open(src).convert('RGB').resize((px,px),Image.Resampling.LANCZOS).save(folder/'ic_launcher.png')
# Android native splash background for launch before Flutter loads
for folder in (res/'drawable',res/'drawable-v21'):
    folder.mkdir(parents=True,exist_ok=True)
    (folder/'launch_background.xml').write_text('<?xml version="1.0" encoding="utf-8"?>\n<layer-list xmlns:android="http://schemas.android.com/apk/res/android">\n  <item android:drawable="#0B0915" />\n</layer-list>')
print('Installed Celyah launcher icons and dark native splash')
