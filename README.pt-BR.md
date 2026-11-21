# Develop

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · **Português (Brasil)**

> *"Eu fotografo com mirrorless e com filme, e posso dizer com sinceridade que os resultados do Develop parecem filme de
> verdade. Ele não pinta um visual de filme sobre a foto com curvas e LUTs: expõe as camadas de corante do filme à luz da
> cena, revela-as e amplia o negativo no papel, como num laboratório. O que sai não é uma imitação de filme. É o que
> aquele filme teria feito com a mesma luz."*
> **jegly**, fotógrafo e autor do Develop

Um laboratório de emulação de filme para Linux. Abra um RAW ou um JPEG, escolha um filme e um papel e obtenha uma
ampliação modelada fisicamente: a luz é seguida pelas camadas de corante do filme e do papel, com grão, halação,
acopladores DIR e o filtro de cor do ampliador, renderizada na sua GPU via Vulkan.

**O Develop é um fork não oficial para Linux do [SpektraLab](https://github.com/JamesQiu2005/SpektraLab)**,
cujo motor deriva do [spektrafilm](https://github.com/andreavolpato/spektrafilm), de Andrea Volpato. Não é afiliado a
nenhum dos dois projetos nem endossado por eles. O modelo de filme, os perfis medidos e o modelo de ampliação e
digitalização são deles; o Develop é o port para Linux e o aplicativo construído sobre ele.

**Usa Mac, iPhone ou iPad? Use o [SpektraLab](https://github.com/JamesQiu2005/SpektraLab).** O Develop é para Linux e
Android; o SpektraLab é o aplicativo original, feito para os dispositivos da Apple.

![Develop no Ubuntu: uma foto de rua em Ilford Delta 100, ampliada em Ilford Multigrade IV RC](screenshots/develop.png)

## O que ele faz

- **130 filmes e papéis**: negativo colorido, cromo, cinema e preto e branco, ampliados em papel colorido ou Multigrade,
  ou digitalizados. Ordenados por marca.
- **O motor inteiro em Vulkan**: todos os efeitos do aplicativo para Mac são renderizados no Linux, incluindo a borda do
  filme e o data back, aberrações de lente e filtros de difusão, vazamentos de luz, o Digital Intermediate, camadas
  locais de cena e a digitalização HDR de cromos.
- **O editor mostra o que é exportado**: a imagem na tela é o arquivo que você recebe.
- Pares de meio quadro, exposições duplas, HSL, mixer de canais, vibração, marcas d'água, vazamentos de luz, caracteres
  de lente e a borda do filme, como no aplicativo para Mac do SpektraLab.
- Exporta em JPEG, PNG e TIFF de 16 bits em sRGB, Display P3, Adobe RGB ou ProPhoto.

## Como o Develop difere do SpektraLab

O SpektraLab é um aplicativo para Mac sobre Metal. O repositório também tem visualizadores para Windows e um motor que
compila no Linux, mas no Linux e no Windows esse motor recusava muitos dos efeitos do Mac. O Develop é um editor
completo para Linux construído sobre esse motor.

**O que o Develop acrescenta**

| | Develop | SpektraLab |
|---|---|---|
| Editor de desktop para Linux | sim, com `.deb` e snap | só o motor e o host |
| Efeitos do motor em Vulkan (Linux, Windows) | todos: borda do filme e data back, Digital Intermediate, latitude de cena, máscara de contraste, aberrações de lente e filtros de difusão, vazamentos de luz, camadas de cena, digitalização HDR de cromos | a maioria recusada |
| Cor em Vulkan | corrigida: uma dominante vermelha em toda renderização Vulkan desde a 2.4.0 (um modo de desfoque que faltava nos kernels Vulkan) | dominante vermelha |
| Filmes e papéis | 130, incluindo 93 novos perfis de filme feitos a partir das folhas de dados publicadas pelos fabricantes | 38 |
| Rede | nenhuma: bloqueada por um filtro seccomp, sem verificação de atualizações | verifica atualizações |
| Correção de lente | o banco de dados do lensfun, mais "Minhas lentes" para lentes manuais que ele não conhece | só no Mac |
| Camadas locais | máscaras graduadas, radiais e de quadro inteiro para exposição e temperatura, sobre as camadas de cena do motor | (recurso do motor) |
| Layouts com várias fotos | dípticos, trípticos, grades e stills de cinema, com espaçamentos e bordas | não |
| Bordas | uma margem de ampliação de qualquer cinza | não |
| Painel avançado | contraste de revelação, suavidade da lente e do scanner, margem nas altas luzes, pontos de branco e preto do scanner | não exposto |

**O que o SpektraLab tem e o Develop não**

- A biblioteca de fotos, a leitura de catálogos do Capture One e a Light Table.
- HDR: mostrar uma imagem numa tela HDR e exportar arquivos HDR (gain map). A digitalização HDR de cromos do motor foi
  portada, mas a visualização web do Linux não consegue mostrar HDR.
- Verificar atualizações. Deixado de fora de propósito: o Develop não tem acesso à rede.
- O aplicativo para iPhone e iPad, e as versões para Mac e Windows.

## Como os novos filmes foram feitos

O SpektraLab traz os 28 perfis medidos do spektrafilm e alguns próprios. O Develop acrescenta 93 perfis de filme, a
maioria de filmes descontinuados há muito tempo, reconstruídos por engenharia reversa a partir das folhas de dados que
seus fabricantes publicaram: o *Professional Data Guide* da Fujifilm (2005), as publicações técnicas da Kodak sobre os
negativos de cinema VISION, os cromos EKTACHROME, ELITE Chrome e KODACHROME e seus negativos fotográficos, e as folhas de
preto e branco da Ilford/HARMAN e da Fujifilm.

1. **Ler as curvas nas folhas.** Para cada filme: a sensibilidade espectral (como cada camada responde a cada
   comprimento de onda), as curvas características (densidade em função da exposição) e as densidades espectrais dos
   corantes (a cor que cada corante absorve). A maioria das folhas são PDFs que guardam os gráficos como traçados
   vetoriais, então os digitalizadores em `engine/tools/fujifilm_data_guide/` leem as curvas direto desses traçados. Cada
   eixo é ajustado pelas próprias linhas de grade e rótulos do gráfico, o que deixa apenas o erro de desenho da própria
   editora. Gráficos que são só imagens são decalcados a 600 dpi.
2. **Transformá-las em perfis.** As curvas passam pela própria fábrica de perfis do spektrafilm e depois pelas mesmas
   regras dos perfis publicados do spektrafilm. Todo ajuste que depende do motor (o filtro de cor do papel, a rampa de
   cinzas, o grão) é calculado pelo próprio motor. Quando falta algo numa folha (algumas folhas do VISION não têm curva
   neutra nem curva de D-min), isso é derivado dos próprios dados do filme e o `metadata` do perfil registra isso.
3. **Verificar o método com filmes comparáveis.** A mesma cadeia foi executada sobre os dados brutos do spektrafilm para
   filmes que ele já tem. Pro 400H, Velvia 100, Vision3 500T, Kodachrome 64 e Ektachrome 100 ficam a ΔE2000 de 1,0 a 2,1
   (média, num ColorChecker) dos perfis medidos do spektrafilm. O digitalizador também reproduz as curvas brutas do
   Kodachrome 64 do spektrafilm a partir da folha da Kodak com diferença de até 0,009.

Cada perfil registra a publicação de origem e os erros de ajuste no seu `metadata`, e
`engine/resources_product/NOTICE.md` lista todos. São reconstruções a partir de dados publicados, não medições de filme
real. Ficam tão perto de cada filme quanto a folha do fabricante permite.

## Sem rede, por projeto

O Develop não consegue acessar a internet. Um filtro seccomp instalado antes de qualquer outra coisa iniciar só permite
sockets locais, e o aplicativo se recusa a rodar se o filtro não puder ser aplicado. Ele vale para a janela, sua
visualização web e o motor. Não há verificação de atualizações, telemetria, fontes remotas nem contas. Suas fotos nunca
saem da sua máquina.

## Branches

| Branch | O que é |
|---|---|
| `main` | O Develop para Linux e o motor sobre o qual todos os aplicativos são construídos |
| `camera` | Develop Camera: uma câmera de filme para Android, em `camera/` |
| `android` | O editor do Develop no Android (em desenvolvimento) |

Cada branch de aplicativo parte de `main`, então as correções do motor chegam a todos.

## Develop Camera (Android)

Uma câmera de filme para Android 17 que fotografa através dos modelos de filme do Develop. Escolha um dos 121 filmes do
Develop e veja-o ao vivo no visor. Cada foto é depois revelada pelo mesmo motor, na GPU do celular: o filme, seu papel,
grão, halação e o resto, como no aplicativo de desktop.

- Revelada a partir dos dados RAW do sensor, com as correções da própria câmera para cada quadro.
- Grão, halação, filtros de difusão, caracteres de lente, filtros de preto e branco, puxar e empurrar, vazamentos de luz,
  a borda do filme e o data back.
- 35 mm, pares de meio quadro, XPan, trípticos e exposições múltiplas, e 120 de 6×4,5 a 6×17.
- Automático com trava de exposição, ou obturador e ISO manuais.
- Pede só a permissão de câmera e não tem acesso à rede. As fotos vão para `DCIM/Develop Camera`.

Testado num Pixel 11 Pro Fold. A GPU dele pulava três dos kernels de lente do motor, o que deixava preta toda
renderização com difusão; esses kernels estão corrigidos em `main`. Os passos de compilação estão em `camera/BUILD.md`.

## O editor do Develop no Android

Um port do editor do Linux para o Android, no branch `android`. Ele mantém o layout de desktop, com ajustes para toque.
Ainda não está pronto para uso.

## Instalação

Baixe o `.deb` ou o snap da [versão mais recente](https://github.com/jegly/Develop/releases/latest) e instale um deles:

```sh
sudo apt install ./Develop_1.0.0_amd64.deb
sudo snap install --dangerous ./develop_1.0.0_amd64.snap
```

O snap precisa de `--dangerous` porque é instalado a partir de um arquivo, e não da Snap Store. Ou compile a partir do código-fonte (abaixo).

O Develop precisa de uma GPU com driver Vulkan. Ele foi desenvolvido no Ubuntu 26.04 com gráficos Intel (Mesa). O `.deb`
instala `libvulkan1`, `liblensfun1`, `liblensfun-data-v1`, `fonts-urw-base35`, `fonts-liberation-sans-narrow` e
`fonts-dejavu-core`. O snap traz suas próprias cópias.

## Compilação

```sh
engine/build-linux.sh                 # the engine and its host, staged in build/host-linux-x64
cd desktop && npm ci
npx tauri build --no-bundle           # the app: desktop/src-tauri/target/release/develop
SPEKTRALAB_BUNDLES=deb node scripts/package.mjs linux    # .deb in desktop/release/linux
sh scripts/build-snap.sh              # snap from that .deb, in desktop/release/snap
```

Para compilar é preciso um compilador C++20, CMake, Ninja, os cabeçalhos do Vulkan e `glslangValidator`, Node 22 com npm,
Rust (stable), os pacotes de desenvolvimento do WebKitGTK 4.1 que o Tauri pede e `liblensfun-dev` para a correção de
lente (compila sem ele, mas sem esse recurso).

## Testes

```sh
(cd build/linux && ctest)             # the Vulkan kernels against float64 references
python3 engine/tests/host_smoke.py --host build/host-linux-x64/spektralab-host \
    --resources build/host-linux-x64/engine
(cd desktop && npm run check)         # typecheck, lint, unit tests
(cd desktop/src-tauri && cargo test)  # includes the no-network test
```

As verificações do motor do projeto original (`engine/tests/*_checks.py`) também rodam contra o motor do Linux.

## Créditos e licença

**O Develop é baseado no SpektraLab, cujo motor deriva do spektrafilm, de Andrea Volpato (GPL-3.0-or-later).** Os 28
perfis medidos de filme e papel do spektrafilm e os LUTs de ampliação são usados sem modificação. Os demais perfis foram
feitos a partir das folhas de dados publicadas pelos fabricantes (`engine/resources_product/NOTICE.md`). Os nomes de
filmes e papéis são marcas de seus donos; eles indicam a partir de quais dados publicados um perfil foi feito.

| | |
|---|---|
| o aplicativo e o motor | GPL-3.0-or-later (`license/LICENSE`) |
| os perfis de filme e papel do spektrafilm, os LUTs de ampliação | CC BY-SA 4.0 (`license/SPEKTRAFILM_LICENSE.txt`) |
| lensfun (vinculado, e seu banco de dados de lentes) | LGPL-3.0 / CC BY-SA 3.0 |
| stb_truetype | domínio público / MIT |

SpektraLab™ e seu ícone pertencem a seus donos. O Develop usa nome e ícone próprios, como os termos da licença do
SpektraLab pedem aos forks publicados.
