# 当前 RAW 支持范围

更新日期：2026-10-29。适用于 GFX100RF 测试版；测试版不代表所有机型已完成兼容验收。

## 实现与支持口径

原生后端使用 LibRaw 0.22.2，并增加针对 GFX100RF 的色彩系数匹配。格式入口、解码器能力、具体机型实测是三层不同范围：能够选择文件或显示相机内嵌预览，不表示完整 RAW 解码和胶片计算一定成功。

## 已实测的相机样本

| 相机 | 文件类型与尺寸 | 已验证范围 | 证据时间 |
|---|---|---|---|
| 富士 GFX100RF | DSCF1220.RAF，11662 × 8746，约 102MP | compatible16 与 headroom；原图预览、默认胶片效果、full 计算、缓存后期调整；本轮未做导出 | 2026-10-29 最终修复包 |
| 索尼 α7C II / ILCE-7CM2 | ARW，4688 × 7028，约 33MP | 兼容解码、高光扩展、完整胶片处理和 TIFF 导出；已有像素参考对比 | 既往验收；本次未重新测试 Sony |

以上是已有样本的实测结果，不代表这两台相机所有设置、压缩模式或所有文件均已覆盖。

## 已接入的 30 种 RAW 扩展名

| 常见来源 | 扩展名 |
|---|---|
| 索尼 | ARW、SRF、SR2 |
| 佳能 | CR2、CR3、CRW |
| 尼康 | NEF、NRW |
| 富士 | RAF |
| 奥林巴斯 / OM | ORF |
| 松下 | RW2 |
| 宾得 | PEF |
| 三星 | SRW |
| 数字负片格式 | DNG |
| 其他 RAW 入口 | 3FR、ARI、BAY、DCR、ERF、FFF、GPR、IIQ、K25、KDC、MEF、MOS、MRW、RAW、RWL、X3F |

这是当前文件选择器和后端路由的完整扩展名清单，不是全部机型的兼容承诺。具体文件仍取决于内置解码器、压缩方式、传感器布局以及必要的色彩和白平衡数据。上述其他格式大多尚无本项目真实样本验收。

## 两种解码模式

| 模式 | 当前范围 |
|---|---|
| compatible16（兼容模式） | 使用 LibRaw 的原生解码/去马赛克路径，输出 16 位线性 ProPhoto 后转浮点；必须通过有效三通道色彩转换和元数据校验。可进入 LibRaw 的 X-Trans 路径，但本项目尚无 X-Trans 实测验收。 |
| headroom（高光扩展） | 仅常规三色 Bayer、方形像素、未预先应用相机白平衡等符合检查条件的 RAW；保留色彩转换后的负值和超 1 高光。并非全程浮点 RAW 解码。 |

## 已知限制

- **Nikon HE / HE\* 高效率压缩不支持。** 已有 Nikon Z8 HE\* 样本失败证据；其他 NEF 压缩类型需要单独验证。
- headroom 不支持 X-Trans、Foveon、浮点 RAW、sRAW、旋转富士传感器等不符合普通 Bayer 条件的输入。可尝试 compatible16，但不能保证成功。
- 缺少有效相机 RGB → ProPhoto 转换、必要白平衡数据，或文件损坏，会返回明确错误；不会用未经校准的相机 RGB 冒充工作色域。
- GFX100RF 补丁只匹配 Fujifilm 的 `GFX100RF` / `GFX 100RF`、三通道、非 DNG 输入。其矩阵与 LibRaw 现有 GFX 100 II 条目一致，经 RawSpeed 的 GFX100RF 数据核对后复用；没有修改文件报告的机型或传感器几何。
- 本清单不等于镜头自动校正支持清单，也不保证所有 RAW 都有可用的内嵌预览。

## 来源与测试记录

- [扩展名定义](desktop/src/shared/fileTypes.ts)
- [后端格式入口](engine/host/image_io.cpp)
- [解码与压缩限制](engine/src/io/raw_decoder.cpp)
- [GFX100RF 匹配实现](engine/src/io/raw_camera.hpp)
- [本轮 102MP 验收](RAF-102MP-TEST-20261029.md)
- Sony 原生 RAW 历史验收（本机验证存档：`validation/native-raw-phase3/REPORT.md`）
- 高光扩展及 Nikon HE* 历史验收（本机验证存档：`validation/raw-headroom-phase4/REPORT.md`）
- [RawSpeed 相机色彩数据](https://github.com/darktable-org/rawspeed/blob/develop/data/cameras.xml)
