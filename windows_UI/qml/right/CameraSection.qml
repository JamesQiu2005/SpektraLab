import QtQuick

// Input / Camera: the scene's exposure onto the film.
Section {
    title: "输入 / 相机"
    Adjustment { label: "胶片曝光"; setting: "filmExposureEv"; from: -4; to: 4; step: 0.1; decimals: 1; suffix: " EV" }
    Note { text: "在胶片曝光前调整场景亮度。每张照片的效果与裁切自动保存，下次导入时恢复。" }
}
