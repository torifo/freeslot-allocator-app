# Android Release Signing

## Package ID

- `net.riumu.frelocator`

## Debug keystore fingerprints

- `SHA1`: `CC:93:E9:12:02:9C:56:71:3A:23:96:82:55:B3:50:6C:F8:D8:8B:F1`
- `SHA256`: `6A:72:11:47:10:63:C6:A0:02:C7:CC:19:7E:91:A8:DF:72:FC:7A:F9:68:9C:8C:5D:7E:D2:A5:E7:E4:11:FF:A8`

## Release keystore

- Path: local machine only, not committed
- Alias: `frelocator`

## Release keystore fingerprints

- `SHA1`: `F3:3C:70:B0:F0:19:89:0B:CE:01:26:D4:78:E4:90:77:75:EA:3B:41`
- `SHA256`: `AE:C1:27:E8:CE:4A:0B:69:76:25:05:FD:E0:46:6A:7B:5B:AC:1A:36:1D:E0:B4:E7:A1:80:85:E4:C4:92:FF:E0`

## Local project wiring

- Local signing file: `android/key.properties`
- Gradle reads `android/key.properties` from `android/app/build.gradle.kts`
- `android/key.properties` is ignored by git and should keep the real passwords only on the local machine

## Next step

- Replace the placeholder passwords in `android/key.properties`
- Build with `flutter build appbundle`
