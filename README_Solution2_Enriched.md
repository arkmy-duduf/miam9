# miam9 — Solution 2 enrichie (CI dans `app/` + APK debug + split APK + AAB)

## Dossier
- `app/` → code Flutter (Android)
- `.github/workflows/android-apk.yml` → workflow CI :
  - Génère **APK debug** (installable direct pour tester)
  - Génère **APK release split par ABI** (installables si signés)
  - Génère **AAB** (pour Play Store)
  - Crée `android/` si absent et injecte la permission **CAMERA** dans le `AndroidManifest.xml` pendant le build

## Utilisation
1. Dézippe à la **racine** de ton repo `miam9/`.
2. Commit & push :
   ```bash
   git add .
   git commit -m "ci: workflow APK/AAB (app/) + app scanner"
   git push
   ```
3. Va dans **Actions** → *Android APK (Flutter)* → télécharge les artifacts :
   - **app-debug-apk** → `app-debug.apk` (installable immédiatement)
   - **app-split-apks** → plusieurs APK par architecture (release)
   - **app-bundle-aab** → `.aab` (Play Console)

### Installer l’APK debug
- Via **ADB** :
  ```bash
  adb install app-debug.apk
  ```
- Ou transfère le fichier sur le téléphone et installe en autorisant les sources inconnues.

### (Optionnel) APK/AAB **signés** en release
Ajoute ces **secrets** dans *Settings → Secrets and variables → Actions* :
- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_PASSWORD`
- `ANDROID_KEY_ALIAS`

Le job `build-release-signed` publiera alors :
- `app-release-apk-signed`
- `app-bundle-aab-signed`

### Remarque
La permission **CAMERA** est automatiquement ajoutée par la CI au `AndroidManifest.xml` généré.
