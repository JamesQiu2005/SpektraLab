# Develop Camera: building

The Android app in this folder builds Develop's engine from this repository's `engine/`. It targets Android 17
(API 37), arm64, and asks for the camera permission only.

## Needs

- JDK 17 or later.
- Android SDK with `platform-tools`, `platforms;android-37.0`, `build-tools;37.0.0`, `ndk;30.0.16248370` and
  `cmake;4.1.2`. Point `local.properties` at it: `sdk.dir=/path/to/Android/Sdk`.
- `glslangValidator` (Khronos glslang) for the engine's Vulkan kernels.
- Python 3 and a Linux machine with Vulkan (GPU or Mesa lavapipe) to bake the viewfinder's film LUTs.

## Steps

From `camera/`:

```bash
bash tools/engine/stage.sh                 # engine resources + SPIR-V kernels -> app/src/main/assets/engine
bash tools/lut-bake/build.sh               # builds the LUT baker against engine/, writes out/jobs.tsv, out/films.json
tools/lut-bake/out/bake app/src/main/assets/engine tools/lut-bake/out/jobs.tsv tools/lut-bake/out/luts
sh tools/lut-bake/stage.sh                 # films.json + LUTs -> app/src/main/assets
./gradlew assembleDebug
```

The Gradle wrapper checks the Gradle download against its published SHA-256.

## Licence

GPL-3.0-or-later, as Develop's engine. Film and paper profiles and the LUTs made from them are CC BY-SA 4.0
(spektrafilm). The texts ship in the app under Settings, Licences.
