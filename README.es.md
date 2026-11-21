# Develop

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · **Español** · [Deutsch](README.de.md) · [Français](README.fr.md) · [Português (Brasil)](README.pt-BR.md)

> *"Fotografío tanto con mirrorless como con película, y puedo decir con sinceridad que los resultados de Develop
> parecen película de verdad. No pinta un aspecto de película sobre una foto con curvas y LUT: expone las capas de
> colorante de la película a la luz de la escena, las revela e imprime el negativo en papel, como en un cuarto oscuro.
> Lo que sale no es una imitación de la película. Es lo que esa película habría hecho con la misma luz."*
> **jegly**, fotógrafo y autor de Develop

Un cuarto oscuro de emulación de película para Linux. Abre un RAW o un JPEG, elige una película y un papel, y obtén
una copia modelada físicamente: la luz se sigue a través de las capas de colorante de la película y del papel, con grano,
halación, acopladores DIR y el filtro de color de la ampliadora, renderizado en tu GPU mediante Vulkan.

**Develop es un fork no oficial para Linux de [SpektraLab](https://github.com/JamesQiu2005/SpektraLab)**,
cuyo motor deriva de [spektrafilm](https://github.com/andreavolpato/spektrafilm), de Andrea Volpato. No está afiliado
a ninguno de los dos proyectos ni cuenta con su respaldo. El modelo de película, los perfiles medidos y el modelo de
copia y escaneo son suyos; Develop es el port para Linux y la aplicación construida sobre él.

**¿Usas un Mac, iPhone o iPad? Usa [SpektraLab](https://github.com/JamesQiu2005/SpektraLab).** Develop es para Linux y
Android; SpektraLab es la aplicación original, hecha para los dispositivos de Apple.

![Develop en Ubuntu: una foto callejera en Ilford Delta 100, positivada en Ilford Multigrade IV RC](screenshots/develop.png)

## Qué hace

- **130 películas y papeles**: negativo en color, diapositiva, cine y blanco y negro, positivados en papel de color o
  Multigrade, o escaneados. Ordenados por marca.
- **Todo el motor en Vulkan**: cada efecto de la aplicación de Mac se renderiza en Linux, incluidos el borde de la
  película y el respaldo de fecha, las aberraciones de lente y los filtros de difusión, las fugas de luz, el Digital
  Intermediate, las capas locales de escena y el escaneo HDR de diapositivas.
- **El editor muestra lo que se exporta**: la imagen en pantalla es el archivo que obtienes.
- Pares de medio formato, dobles exposiciones, HSL, mezclador de canales, intensidad, marcas de agua, fugas de luz,
  caracteres de lente y el borde de la película, como en la aplicación de Mac de SpektraLab.
- Exporta a JPEG, PNG y TIFF de 16 bits en sRGB, Display P3, Adobe RGB o ProPhoto.

## En qué se diferencia Develop de SpektraLab

SpektraLab es una aplicación de Mac sobre Metal. Su repositorio también tiene visores para Windows y un motor que se
compila en Linux, pero en Linux y Windows ese motor rechazaba muchos de los efectos del Mac. Develop es un editor
completo para Linux construido sobre ese motor.

**Lo que añade Develop**

| | Develop | SpektraLab |
|---|---|---|
| Editor de escritorio para Linux | sí, con un `.deb` y un snap | solo el motor y el host |
| Efectos del motor en Vulkan (Linux, Windows) | todos: borde de película y respaldo de fecha, Digital Intermediate, latitud de escena, máscara de contraste, aberraciones de lente y filtros de difusión, fugas de luz, capas de escena, escaneo HDR de diapositivas | la mayoría rechazados |
| Color en Vulkan | corregido: una dominante roja en cada render de Vulkan desde la 2.4.0 (un modo de desenfoque que faltaba en los kernels de Vulkan) | dominante roja |
| Películas y papeles | 130, incluidos 93 perfiles de película nuevos hechos a partir de las hojas técnicas publicadas por los fabricantes | 38 |
| Red | ninguna: bloqueada por un filtro seccomp, sin búsqueda de actualizaciones | busca actualizaciones |
| Corrección de lente | la base de datos de lensfun, más "Mis lentes" para lentes manuales que no conoce | solo en Mac |
| Capas locales | máscaras graduadas, radiales y de toda la imagen para exposición y calidez, sobre las capas de escena del motor | (función del motor) |
| Composiciones de varias fotos | dípticos, trípticos, cuadrículas y fotogramas cinematográficos, con separación y bordes | no |
| Bordes | un borde de copia de cualquier gris | no |
| Panel avanzado | contraste de revelado, suavidad de lente y escáner, margen de altas luces, puntos blanco y negro del escáner | no expuesto |

**Lo que SpektraLab tiene y Develop no**

- La fototeca, la lectura de catálogos de Capture One y la Light Table.
- HDR: mostrar una imagen en una pantalla HDR y exportar archivos HDR (gain map). El escaneo HDR de diapositivas del
  motor está portado, pero la vista web de Linux no puede mostrar HDR.
- Buscar actualizaciones. Omitido a propósito: Develop no tiene acceso a la red.
- La aplicación para iPhone y iPad, y las versiones para Mac y Windows.

## Cómo se hicieron las películas nuevas

SpektraLab incluye los 28 perfiles medidos de spektrafilm y algunos propios. Develop añade 93 perfiles de película, la
mayoría de películas descatalogadas hace mucho, reconstruidos por ingeniería inversa a partir de las hojas técnicas que
publicaron sus fabricantes: la *Professional Data Guide* de Fujifilm (2005), las publicaciones técnicas de Kodak sobre
los negativos de cine VISION, las diapositivas EKTACHROME, ELITE Chrome y KODACHROME y sus negativos de fotografía, y las
hojas de blanco y negro de Ilford/HARMAN y Fujifilm.

1. **Leer las curvas de las hojas.** Para cada película: su sensibilidad espectral (cómo responde cada capa a cada
   longitud de onda), sus curvas características (densidad frente a exposición) y sus densidades espectrales de colorante
   (el color que absorbe cada colorante). La mayoría de las hojas son PDF que guardan sus gráficos como trazados
   vectoriales, así que los digitalizadores de `engine/tools/fujifilm_data_guide/` leen las curvas directamente de esos
   trazados. Cada eje se ajusta a las propias líneas de cuadrícula y etiquetas del gráfico, lo que deja solo el error de
   dibujo del propio editor. Los gráficos que solo son imágenes se calcan a 600 ppp.
2. **Convertirlas en perfiles.** Las curvas pasan por la propia fábrica de perfiles de spektrafilm y luego por las mismas
   reglas que los perfiles publicados de spektrafilm. Cada ajuste que depende del motor (el filtro de color del papel,
   la rampa de grises, el grano) se ejecuta con el propio motor. Cuando a una hoja le falta algo (algunas hojas de VISION
   no tienen curva neutra ni de D-min), se deriva de los propios datos de la película y el `metadata` del perfil lo indica.
3. **Comprobar el método con películas comparables.** La misma cadena se ejecutó con los datos brutos de spektrafilm para
   películas que ya tiene. Pro 400H, Velvia 100, Vision3 500T, Kodachrome 64 y Ektachrome 100 quedan a ΔE2000 de 1,0 a
   2,1 (media, sobre un ColorChecker) de los perfiles medidos de spektrafilm. El digitalizador también reproduce las curvas
   brutas de Kodachrome 64 de spektrafilm a partir de la hoja de Kodak con un margen de 0,009.

Cada perfil registra su publicación de origen y sus errores de ajuste en su `metadata`, y
`engine/resources_product/NOTICE.md` los enumera todos. Son reconstrucciones a partir de datos publicados, no mediciones
de película real. Se acercan a cada película tanto como lo permite la hoja de su fabricante.

## Sin red, por diseño

Develop no puede acceder a internet. Un filtro seccomp instalado antes de que arranque cualquier otra cosa solo permite
sockets locales, y la aplicación se niega a ejecutarse si no puede instalar el filtro. Se aplica a la ventana, a su vista
web y al motor. No hay búsqueda de actualizaciones, telemetría, fuentes remotas ni cuentas. Tus fotos nunca salen de tu
equipo.

## Ramas

| Rama | Qué es |
|---|---|
| `main` | Develop para Linux, y el motor sobre el que se construyen todas las aplicaciones |
| `camera` | Develop Camera: una cámara de película para Android, en `camera/` |
| `android` | El editor de Develop en Android (en desarrollo) |

Cada rama de aplicación parte de `main`, así que las correcciones del motor llegan a todas.

## Develop Camera (Android)

Una cámara de película para Android 17 que dispara a través de los modelos de película de Develop. Elige una de las 121
películas de Develop y mírala en directo en el visor. Cada foto la revela después el mismo motor, en la GPU del teléfono:
la película, su papel, el grano, la halación y lo demás, como en la aplicación de escritorio.

- Revelada a partir de los datos RAW del sensor, con las correcciones propias de la cámara para cada fotograma.
- Grano, halación, filtros de difusión, caracteres de lente, filtros de blanco y negro, forzado y subrevelado, fugas de
  luz, el borde de la película y el respaldo de fecha.
- 35 mm, pares de medio formato, XPan, trípticos y exposiciones múltiples, y 120 de 6×4,5 a 6×17.
- Automático con bloqueo de exposición, o obturador e ISO manuales.
- Solo pide el permiso de cámara y no tiene acceso a la red. Las fotos van a `DCIM/Develop Camera`.

Probada en un Pixel 11 Pro Fold. Su GPU se saltaba tres de los kernels de lente del motor, lo que hacía negro cada render
con difusión; esos kernels están corregidos en `main`. Los pasos de compilación están en `camera/BUILD.md`.

## El editor de Develop en Android

Un port del editor de Linux a Android, en la rama `android`. Mantiene la disposición de escritorio, con ajustes para el
uso táctil. Todavía no está listo para usarse.

## Instalación

Descarga el `.deb` o el snap de la [última versión](https://github.com/jegly/Develop/releases/latest) e instala uno de los dos:

```sh
sudo apt install ./Develop_1.0.0_amd64.deb
sudo snap install --dangerous ./develop_1.0.0_amd64.snap
```

El snap necesita `--dangerous` porque se instala desde un archivo, no desde la Snap Store. También puedes compilarlo desde el código fuente (abajo).

Develop necesita una GPU con un controlador Vulkan. Se ha desarrollado en Ubuntu 26.04 con gráficos Intel (Mesa). El
`.deb` instala `libvulkan1`, `liblensfun1`, `liblensfun-data-v1`, `fonts-urw-base35`, `fonts-liberation-sans-narrow` y
`fonts-dejavu-core`. El snap lleva sus propias copias.

## Compilación

```sh
engine/build-linux.sh                 # the engine and its host, staged in build/host-linux-x64
cd desktop && npm ci
npx tauri build --no-bundle           # the app: desktop/src-tauri/target/release/develop
SPEKTRALAB_BUNDLES=deb node scripts/package.mjs linux    # .deb in desktop/release/linux
sh scripts/build-snap.sh              # snap from that .deb, in desktop/release/snap
```

Para compilar hace falta un compilador de C++20, CMake, Ninja, las cabeceras de Vulkan y `glslangValidator`, Node 22 con
npm, Rust (stable), los paquetes de desarrollo de WebKitGTK 4.1 que pide Tauri y `liblensfun-dev` para la corrección de
lente (compila sin él, pero sin esa función).

## Pruebas

```sh
(cd build/linux && ctest)             # the Vulkan kernels against float64 references
python3 engine/tests/host_smoke.py --host build/host-linux-x64/spektralab-host \
    --resources build/host-linux-x64/engine
(cd desktop && npm run check)         # typecheck, lint, unit tests
(cd desktop/src-tauri && cargo test)  # includes the no-network test
```

Las comprobaciones del motor del proyecto original (`engine/tests/*_checks.py`) también se ejecutan contra el motor de Linux.

## Créditos y licencia

**Develop se basa en SpektraLab, cuyo motor deriva de spektrafilm, de Andrea Volpato (GPL-3.0-or-later).** Los 28
perfiles medidos de película y papel de spektrafilm y los LUT de copia se usan sin modificar. Los demás perfiles se han
hecho a partir de las hojas técnicas publicadas por los fabricantes (`engine/resources_product/NOTICE.md`). Los nombres de
películas y papeles son marcas registradas de sus propietarios; indican a partir de qué datos publicados se hizo un perfil.

| | |
|---|---|
| la aplicación y el motor | GPL-3.0-or-later (`license/LICENSE`) |
| los perfiles de película y papel de spektrafilm, los LUT de copia | CC BY-SA 4.0 (`license/SPEKTRAFILM_LICENSE.txt`) |
| lensfun (enlazado, y su base de datos de lentes) | LGPL-3.0 / CC BY-SA 3.0 |
| stb_truetype | dominio público / MIT |

SpektraLab™ y su icono pertenecen a sus propietarios. Develop usa su propio nombre e icono, como piden los términos de la
licencia de SpektraLab a los forks publicados.
