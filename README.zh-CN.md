# Develop

[English](README.md) · **简体中文**

> *"我同时用无反相机和胶片拍摄，可以坦白地说，Develop 的成片看起来就是真正的胶片。它不是用曲线和 LUT 给照片套上胶片风格，
> 而是让场景的光照到胶片的染料层上，冲洗，再把底片印放到相纸上，就像暗房一样。得到的不是对胶片的模仿，
> 而是那卷胶片面对同样的光会拍出的样子。"*
> **jegly**，摄影师，Develop 作者

Develop 是一款 Linux 上的胶片模拟暗房软件。打开 RAW 或 JPEG，选择胶片与相纸，即可得到基于物理模型的照片：
光线穿过胶片与相纸的染料层，带有颗粒、光晕、DIR 耦合剂和放大机滤镜，通过 Vulkan 在 GPU 上渲染。

**Develop 是 [SpektraLab](https://github.com/JamesQiu2005/SpektraLab) 的非官方 Linux 分支**，其引擎源自
Andrea Volpato 的 [spektrafilm](https://github.com/andreavolpato/spektrafilm)。本项目与二者均无隶属或背书关系。
胶片模型、实测配置文件以及印放与扫描模型属于它们；Develop 是 Linux 移植以及基于其构建的应用。

![Develop 在 Ubuntu 上：街头照片，Ilford Delta 100 胶片，印放于 Ilford Multigrade IV RC 相纸](screenshots/develop.png)

## 要点

- 130 种胶片与相纸（彩色负片、反转片、电影胶片、黑白胶片），按品牌排序。
- 引擎的全部效果均可在 Linux 的 Vulkan 上渲染。
- 编辑器所见即导出所得。
- Develop 自有功能：镜头校正（lensfun 及"我的镜头"）、局部图层、半格双拼、多重曝光、HSL、通道混合器、
  自然饱和度、边框、水印、多图排版，以及 JPEG / PNG / 16 位 TIFF 导出。
- **不联网**：seccomp 过滤器只允许本地套接字，无更新检查、无遥测。照片永远不会离开你的电脑。

构建、测试与许可说明见 [README.md](README.md)。应用与引擎采用 GPL-3.0-or-later；spektrafilm 的配置文件与
印放 LUT 采用 CC BY-SA 4.0。SpektraLab™ 及其图标归其所有者；Develop 使用自己的名称与图标。
