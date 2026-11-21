# Develop

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · **한국어** · [Español](README.es.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Português (Brasil)](README.pt-BR.md)

> *"저는 미러리스와 필름으로 모두 촬영하는데, Develop의 결과물은 진짜 필름처럼 보인다고 솔직하게 말할 수 있습니다.
> 커브와 LUT로 사진 위에 필름 느낌을 덧칠하는 것이 아닙니다. 장면의 빛으로 필름의 염료층을 노광하고, 현상하고,
> 네거티브를 인화지에 인화합니다. 암실과 같은 방식입니다. 나오는 것은 필름의 흉내가 아니라, 그 필름이 같은 빛을 받았다면 만들어 냈을 결과입니다."*
> **jegly**, 사진가, Develop 제작자

Develop은 Linux용 필름 에뮬레이션 암실입니다. RAW나 JPEG를 열고 필름과 인화지를 고르면 물리 모델에 기반한 인화를 얻습니다.
빛은 필름과 인화지의 염료층을 통과하며 추적되고, 그레인, 헐레이션, DIR 커플러, 확대기의 필터 팩이 더해져 Vulkan을 통해 GPU에서 렌더링됩니다.

**Develop은 [SpektraLab](https://github.com/JamesQiu2005/SpektraLab)의 비공식 Linux 포크입니다.** 그 엔진은
Andrea Volpato의 [spektrafilm](https://github.com/andreavolpato/spektrafilm)에서 파생되었습니다. 두 프로젝트 모두와 제휴하거나 승인을 받지 않았습니다.
필름 모델, 측정된 프로파일, 인화와 스캔 모델은 그들의 것이며, Develop은 그 Linux 포팅과 그 위에 만든 앱입니다.

**Mac, iPhone, iPad를 쓰시나요? [SpektraLab](https://github.com/JamesQiu2005/SpektraLab)을 사용하세요.** Develop은 Linux와
Android용이고, SpektraLab은 Apple 기기를 위해 만든 원래 앱입니다.

![Ubuntu의 Develop: Ilford Delta 100으로 찍어 Ilford Multigrade IV RC에 인화한 거리 사진](screenshots/develop.png)

## 기능

- **130가지 필름과 인화지**: 컬러 네거티브, 슬라이드, 영화용, 흑백 필름을 컬러 인화지나 Multigrade 인화지에 인화하거나 스캔합니다. 브랜드별로 정렬됩니다.
- **엔진 전체가 Vulkan에서 동작**: Mac 앱의 모든 효과가 Linux에서 렌더링됩니다. 필름 가장자리와 데이트 백, 렌즈 수차와 디퓨전 필터,
  빛샘, Digital Intermediate, 로컬 장면 레이어, HDR 슬라이드 스캔까지 포함합니다.
- **편집기에 보이는 것이 그대로 내보내집니다**: 화면의 사진이 곧 받게 되는 파일입니다.
- 하프 프레임 쌍, 이중 노출, HSL, 채널 믹서, 자연 채도, 워터마크, 빛샘, 렌즈 캐릭터, 필름 가장자리. SpektraLab의 Mac 앱과 같습니다.
- JPEG, PNG, 16비트 TIFF로 내보내기. 색 공간은 sRGB, Display P3, Adobe RGB, ProPhoto.

## Develop과 SpektraLab의 차이

SpektraLab은 Metal 기반의 Mac 앱입니다. 저장소에는 Windows 뷰어와 Linux에서 빌드되는 엔진도 있지만,
Linux와 Windows에서는 그 엔진이 Mac의 많은 효과를 거부했습니다. Develop은 그 엔진 위에 만든 완전한 Linux 편집기입니다.

**Develop이 더한 것**

| | Develop | SpektraLab |
|---|---|---|
| Linux 데스크톱 편집기 | 있음, `.deb`와 snap 제공 | 엔진과 호스트만 |
| Vulkan의 엔진 효과(Linux, Windows) | 전부: 필름 가장자리와 데이트 백, Digital Intermediate, 장면 관용도, 콘트라스트 마스크, 렌즈 수차와 디퓨전 필터, 빛샘, 장면 레이어, HDR 슬라이드 스캔 | 대부분 거부됨 |
| Vulkan의 색 | 수정됨: 2.4.0부터 모든 Vulkan 렌더링에 붉은 색조(Vulkan 커널에 없던 블러 모드) | 붉은 색조 |
| 필름과 인화지 | 130가지, 제조사가 공개한 데이터 시트로 만든 새 필름 프로파일 93개 포함 | 38가지 |
| 네트워크 | 없음: seccomp 필터로 차단, 업데이트 확인 없음 | 업데이트 확인 |
| 렌즈 보정 | lensfun 데이터베이스, 그리고 거기에 없는 수동 렌즈를 위한 "내 렌즈" | Mac에서만 |
| 로컬 레이어 | 그라디언트, 원형, 전체 마스크로 노출과 색온도 조정, 엔진의 장면 레이어 기반 | (엔진 기능) |
| 여러 장 레이아웃 | 두 장, 세 장, 그리드, 시네마틱 스틸, 간격과 테두리 포함 | 없음 |
| 테두리 | 원하는 회색의 인화 테두리 | 없음 |
| 고급 패널 | 현상 콘트라스트, 렌즈와 스캐너의 부드러움, 하이라이트 여유, 스캐너 화이트·블랙 포인트 | 공개 안 됨 |

**SpektraLab에는 있고 Develop에는 없는 것**

- 사진 라이브러리, Capture One 카탈로그 읽기, Light Table.
- HDR: HDR 화면에 사진 표시와 HDR(게인 맵) 파일 내보내기. 엔진의 HDR 슬라이드 스캔은 포팅되었지만 Linux의 웹 뷰는 HDR을 표시할 수 없습니다.
- 업데이트 확인. 일부러 뺐습니다: Develop은 네트워크에 접속하지 않습니다.
- iPhone과 iPad 앱, 그리고 Mac과 Windows용 빌드.

## 새 필름은 어떻게 만들었나

SpektraLab에는 spektrafilm의 측정 프로파일 28개와 자체 프로파일 몇 개가 들어 있습니다. Develop은 필름 프로파일 93개를 더했습니다.
대부분 오래전에 단종된 필름이며, 제조사가 공개한 데이터 시트로부터 역산했습니다: 후지필름의 *Professional Data Guide*(2005),
VISION 영화용 네거티브, EKTACHROME, ELITE Chrome, KODACHROME 슬라이드와 스틸 네거티브에 대한 Kodak의 기술 자료,
그리고 Ilford/HARMAN과 후지필름의 흑백 데이터 시트입니다.

1. **데이터 시트에서 곡선을 읽습니다.** 필름마다: 분광 감도(각 층이 각 파장에 어떻게 반응하는지), 특성 곡선(노광량에 따른 농도),
   분광 염료 농도(각 염료가 흡수하는 색). 대부분의 데이터 시트는 그래프를 벡터 경로로 저장한 PDF라서, `engine/tools/fujifilm_data_guide/`의
   디지타이저가 그 경로에서 곡선을 바로 읽습니다. 각 축은 그래프 자체의 격자선과 라벨에 맞추므로, 남는 것은 발행처 자신의 작도 오차뿐입니다.
   이미지로만 된 그래프는 600 dpi로 트레이스합니다.
2. **프로파일로 만듭니다.** 곡선은 spektrafilm 자체의 프로파일 생성 과정을 거친 뒤, spektrafilm이 배포한 프로파일과 같은 규칙을 따릅니다.
   엔진에 의존하는 모든 피팅(인화지의 필터 팩, 회색 램프, 그레인)은 엔진 자체로 실행합니다. 데이터 시트에 빠진 것이 있으면
   (일부 VISION 데이터 시트에는 중성 곡선이나 D-min 곡선이 없음) 그 필름 자체의 데이터로 도출하고, 프로파일의 `metadata`에 그렇게 적습니다.
3. **비교할 수 있는 필름으로 방법을 검증합니다.** 같은 과정을 spektrafilm이 이미 가진 필름의 원본 데이터에도 실행했습니다. Pro 400H, Velvia 100,
   Vision3 500T, Kodachrome 64, Ektachrome 100은 spektrafilm의 측정 프로파일과 ΔE2000 1.0~2.1(ColorChecker 평균) 이내로 나옵니다.
   디지타이저는 Kodak 데이터 시트로부터 spektrafilm의 Kodachrome 64 원본 곡선을 0.009 이내로 재현합니다.

각 프로파일은 출처 자료와 피팅 오차를 `metadata`에 기록하며, `engine/resources_product/NOTICE.md`에 모두 정리되어 있습니다.
이는 공개 데이터로부터의 재구성이지 실제 필름의 측정이 아닙니다. 제조사의 데이터 시트가 허락하는 한 각 필름에 가깝습니다.

## 설계상 네트워크 없음

Develop은 인터넷에 접속할 수 없습니다. 다른 무엇보다 먼저 설치되는 seccomp 필터가 로컬 소켓만 허용하며, 필터를 설치할 수 없으면
앱은 실행을 거부합니다. 이는 창, 그 웹 뷰, 엔진 모두에 적용됩니다. 업데이트 확인, 원격 측정, 원격 글꼴, 계정이 없습니다. 사진은 절대 컴퓨터 밖으로 나가지 않습니다.

## 브랜치

| 브랜치 | 내용 |
|---|---|
| `main` | Linux용 Develop, 그리고 모든 앱이 기반으로 하는 엔진 |
| `camera` | Develop Camera: Android용 필름 카메라, `camera/`에 있음 |
| `android` | Android용 Develop 편집기(개발 중) |

각 앱 브랜치는 `main`에서 시작하므로 엔진 수정이 모든 브랜치에 반영됩니다.

## Develop Camera(Android)

Develop의 필름 모델로 촬영하는 Android 17용 필름 카메라입니다. Develop의 121가지 필름 중 하나를 고르면 뷰파인더에서 실시간으로 볼 수 있습니다.
찍은 사진은 같은 엔진으로 휴대폰의 GPU에서 현상됩니다: 필름, 인화지, 그레인, 헐레이션 등, 데스크톱 앱과 같습니다.

- 센서의 RAW 데이터에서, 프레임마다 카메라 자체의 보정을 사용해 현상.
- 그레인, 헐레이션, 디퓨전 필터, 렌즈 캐릭터, 흑백 필터, 증감과 감감, 빛샘, 필름 가장자리와 데이트 백.
- 35 mm, 하프 프레임 쌍, XPan, 세 장 구성, 다중 노출, 그리고 6×4.5부터 6×17까지의 120.
- 노출 고정이 있는 자동, 또는 수동 셔터와 ISO.
- 카메라 권한만 요청하고 네트워크에 접속하지 않습니다. 사진은 `DCIM/Develop Camera`에 저장됩니다.

Pixel 11 Pro Fold에서 테스트했습니다. 그 GPU가 엔진의 렌즈 커널 세 개를 건너뛰어 디퓨전 렌더링이 모두 검게 나왔는데, 이 커널들은 `main`에서 수정되었습니다.
빌드 방법은 `camera/BUILD.md`에 있습니다.

## Android용 Develop 편집기

Linux 편집기를 Android로 옮긴 것으로, `android` 브랜치에 있습니다. 데스크톱 레이아웃을 유지하고 터치용 수정을 더했습니다. 아직 사용할 수 있는 상태는 아닙니다.

## 설치

아직 공개된 릴리스가 없습니다. 소스에서 빌드하세요(아래 참조). 빌드하면 `.deb`와 snap이 만들어집니다.

Develop에는 Vulkan 드라이버가 있는 GPU가 필요합니다. Ubuntu 26.04와 Intel 그래픽(Mesa)에서 개발되었습니다. `.deb`는 `libvulkan1`, `liblensfun1`,
`liblensfun-data-v1`, `fonts-urw-base35`, `fonts-liberation-sans-narrow`, `fonts-dejavu-core`를 설치합니다. snap은 자체 사본을 포함합니다.

## 빌드

```sh
engine/build-linux.sh                 # the engine and its host, staged in build/host-linux-x64
cd desktop && npm ci
npx tauri build --no-bundle           # the app: desktop/src-tauri/target/release/develop
SPEKTRALAB_BUNDLES=deb node scripts/package.mjs linux    # .deb in desktop/release/linux
sh scripts/build-snap.sh              # snap from that .deb, in desktop/release/snap
```

빌드에는 C++20 컴파일러, CMake, Ninja, Vulkan 헤더와 `glslangValidator`, npm이 포함된 Node 22, Rust(stable),
Tauri가 요구하는 WebKitGTK 4.1 개발 패키지, 그리고 렌즈 보정용 `liblensfun-dev`(없어도 빌드되지만 그 기능은 빠집니다)가 필요합니다.

## 테스트

```sh
(cd build/linux && ctest)             # the Vulkan kernels against float64 references
python3 engine/tests/host_smoke.py --host build/host-linux-x64/spektralab-host \
    --resources build/host-linux-x64/engine
(cd desktop && npm run check)         # typecheck, lint, unit tests
(cd desktop/src-tauri && cargo test)  # includes the no-network test
```

업스트림의 엔진 검사(`engine/tests/*_checks.py`)도 Linux 엔진에 대해 실행됩니다.

## 크레딧과 라이선스

**Develop은 SpektraLab을 기반으로 하며, 그 엔진은 Andrea Volpato의 spektrafilm(GPL-3.0-or-later)에서 파생되었습니다.**
spektrafilm의 측정된 필름·인화지 프로파일 28개와 인화 LUT는 수정 없이 사용합니다. 나머지 프로파일은 제조사가 공개한 데이터 시트로 만들었습니다
(`engine/resources_product/NOTICE.md`). 필름과 인화지 이름은 해당 소유자의 상표이며, 프로파일이 어떤 공개 데이터로 만들어졌는지를 나타냅니다.

| | |
|---|---|
| 앱과 엔진 | GPL-3.0-or-later(`license/LICENSE`) |
| spektrafilm의 필름·인화지 프로파일, 인화 LUT | CC BY-SA 4.0(`license/SPEKTRAFILM_LICENSE.txt`) |
| lensfun(링크, 그리고 렌즈 데이터베이스) | LGPL-3.0 / CC BY-SA 3.0 |
| stb_truetype | 퍼블릭 도메인 / MIT |

SpektraLab™과 그 아이콘은 해당 소유자의 것입니다. SpektraLab의 라이선스 조건이 공개 포크에 요구하는 대로, Develop은 자체 이름과 아이콘을 사용합니다.
