# This is the PRD for many of the small frontend changes, I'll describe them one by one

## The problem with the macOS traffic light
with the current setup the obvious problem is that the traffic light is at a fixed position during windows session, and there's some real bug. See /Users/xiaojinqiu/Documents/Summer 2026/filmify/PRD/frontend_bug/traffic_light_overlay.png. I'm purposing one fix of expanding the top bar, making it non-collapsable so it's gonna host everything anyways. reference top image is in PRD/new_frontend_top_layout.png. Note that the zoom in and zoom out has switched position, and only the expand button exists, and it works as both expanding and shrinking at one place.

## 控制 control asset 的 button 要做成收缩的
So effectively that button to expand / collapse the control bars should be hidden by default and only shows up when the mouse reaches the side of the control asset and is near the where they originally are, and it has to also be hidden and then appear when the mouse is near even after the side bar collapsing. Quite a lot of control difference but you should be able to handle it well.

## Write the settings page for me
according to the current layout of the base page, write the settings page, reachable from macOS's top filmify -> settings, include all the adjustable params we've discussed, and they should be in RFC-016

## Crop orientation modification

现在的crop在选择比例的时候只支持，原有的是 horizontal 那 crop 的也只有 horizontal，反之亦然，我希望变成类似 capture one 的方式。见PRD/capture_one_crop_reference.png。 注意不需要添加裁剪比例，只是要加一个选择方向的旋转功能

## No bottom right white dot for selected image at the bottom opened-image tab

只需要有外围的白框代表被选定就行了，不需要其它的。

## Canvas strocking when moving layout

显示的图像不知道为什么在延展/收缩两侧control的时候，还有改变app窗口大小的时候都会抽动，解决这个bug

## No Batch processing yet

DO NOT IMPLEMENT RFC 0017 or change the code related to that

## Better export page

Make reference to the capture one reference in PRD/export_page_reference_capture_one.png, but keep the actual UI implementation our filmify style. Include the different export formula option (set in some separated json), and the export formula and adjust which folder, whether to have sub folder, change the name, and choose format (No need to be that specific, but remember our JPEG, PNG 8-bit, TIFF 16-bit, and DI package option), and the export color space can be adjusted (available color space read from the system)