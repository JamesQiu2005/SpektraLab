sRGB.icc is a standard sRGB matrix/TRC profile generated once with
Pillow 12.3.0 ImageCms (LittleCMS 2.19), using
ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes().
It is committed as a runtime resource; Python/LittleCMS are not runtime
dependencies of the Windows application. It is not a monitor calibration.
588 bytes, SHA256:
f869f25625302eef46cd74fe56ec11adbfa7cf20db6f70b8efdddcbeec4323a0
The profile contains a generation timestamp, so re-generation changes bytes.
Used only for encoded sRGB RGB16 TIFF exports; no HDR/EDR tagging is implied.
