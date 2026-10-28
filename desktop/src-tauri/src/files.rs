//! The file system the webview may touch, as narrow commands rather than the
//! fs plugin's general access: list a folder's photographs, and read and write
//! a frame's sidecar in the app's own store.
//!
//! Sidecars (ARCHITECTURE.md §7.6, AGENTS.md trap 35) live in
//! `<app data>/Sidecars/<file>-<sha256(path)[:16]>.spektra.json`, never beside
//! the photograph. The JSON is the macOS `Sidecar` shape; the webview owns its
//! contents and this module owns where it goes. A sidecar carries `source`
//! (path, size, inode, volume) so a moved file is recognised; the old
//! `<image>.spektra.json` beside the photo is migrated (moved) on first read.

use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

pub const IMAGE_EXTENSIONS: &[&str] = &[
    // RAW (LibRaw)
    "3fr", "ari", "arw", "bay", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "gpr", "iiq", "k25", "kdc", "mef",
    "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw", "x3f",
    // rasters
    "tif", "tiff", "jpg", "jpeg", "png", "heic", "heif", "hif", "exr",
];

pub fn is_image(p: &Path) -> bool {
    p.extension()
        .and_then(|e| e.to_str())
        .map(|e| IMAGE_EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}

#[derive(Serialize)]
pub struct Entry {
    pub path: String,
    pub name: String,
    pub size: u64,
    pub mtime_ms: f64,
}

pub(crate) fn entry(p: &Path) -> Option<Entry> {
    let md = fs::metadata(p).ok()?;
    let mtime_ms = md
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0);
    Some(Entry {
        path: p.display().to_string(),
        name: p.file_name()?.to_string_lossy().into_owned(),
        size: md.len(),
        mtime_ms,
    })
}

/// Photographs in the folder and its children, without following links or
/// Windows junctions (a linked parent could otherwise recurse forever).
pub fn list_images(dir: &Path) -> Result<Vec<Entry>, String> {
    let mut pending = vec![dir.to_path_buf()];
    let mut out = Vec::new();
    while let Some(folder) = pending.pop() {
        let rd = fs::read_dir(&folder).map_err(|e| format!("{}: {e}", folder.display()))?;
        for d in rd {
            let d = d.map_err(|e| e.to_string())?;
            if d.file_name().to_string_lossy().starts_with('.') { continue; }
            let md = fs::symlink_metadata(d.path()).map_err(|e| e.to_string())?;
            if md.file_type().is_symlink() { continue; }
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                // FILE_ATTRIBUTE_REPARSE_POINT or FILE_ATTRIBUTE_HIDDEN.
                if md.file_attributes() & (0x400 | 0x2) != 0 { continue; }
            }
            if md.is_dir() { pending.push(d.path()); }
            else if md.is_file() && is_image(&d.path()) {
                if let Some(e) = entry(&d.path()) { out.push(e); }
            }
        }
    }
    out.sort_by_key(|e| (e.name.to_lowercase(), e.path.to_lowercase()));
    Ok(out)
}

/// Dropped or argv paths → photographs: files kept if they are images, a
/// directory expanded recursively.
pub fn expand(paths: &[String]) -> Vec<Entry> {
    let mut out = Vec::new();
    for p in paths {
        let path = PathBuf::from(p);
        if path.is_dir() {
            if let Ok(mut v) = list_images(&path) {
                out.append(&mut v);
            }
        } else if path.is_file() && (is_image(&path) || crate::pairs::is_pair(&path)) {
            if let Some(e) = entry(&path) {
                out.push(e);
            }
        }
    }
    out
}

/// The path the sidecar key hashes: absolute, `.`/`..` resolved, without
/// following symlinks (as `URL.standardizedFileURL` does on macOS).
pub fn standardized(p: &Path) -> PathBuf {
    let abs = if p.is_absolute() {
        p.to_path_buf()
    } else {
        std::env::current_dir().map(|d| d.join(p)).unwrap_or_else(|_| p.to_path_buf())
    };
    let mut out = PathBuf::new();
    for c in abs.components() {
        match c {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out
}

pub fn sidecar_key(image: &Path) -> String {
    let path = standardized(image);
    let digest = Sha256::digest(path.to_string_lossy().as_bytes());
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    let name = image.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    format!("{name}-{}.spektra.json", &hex[..16])
}

pub fn identity(image: &Path) -> Value {
    let path = standardized(image).display().to_string();
    let mut v = json!({"path": path});
    if let Ok(md) = fs::metadata(image) {
        v["size"] = json!(md.len());
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            v["inode"] = json!(md.ino());
            v["volumeID"] = json!(md.dev());
        }
        #[cfg(windows)]
        if let Some((volume, file)) = windows_file_identity(image) {
            // Keep Windows IDs separate from the Mac/Unix integer fields.
            // Strings preserve all 128 bits through the JavaScript sidecar.
            v["windowsVolumeID"] = json!(volume);
            v["windowsFileID"] = json!(file);
        }
    }
    v
}

#[cfg(windows)]
fn windows_file_identity(image: &Path) -> Option<(String, String)> {
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::AsRawHandle;

    // FILE_ID_INFO, available since Windows 8; unlike a path or content hash,
    // the volume + ID follows a rename but distinguishes an identical copy.
    #[repr(C)]
    struct FileIdInfo {
        volume_serial_number: u64,
        file_id: [u8; 16],
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn GetFileInformationByHandleEx(
            handle: *mut std::ffi::c_void,
            class: i32,
            information: *mut std::ffi::c_void,
            size: u32,
        ) -> i32;
    }
    // Only attributes are requested, with read/write/delete sharing. Saving
    // an edit must not keep the photograph locked against a later rename.
    let file = fs::OpenOptions::new().access_mode(0x80).share_mode(7).open(image).ok()?;
    let mut info = FileIdInfo { volume_serial_number: 0, file_id: [0; 16] };
    // SAFETY: file owns the live handle; the pointer refers to the correctly
    // sized repr(C) buffer for FileIdInfo (FILE_INFO_BY_HANDLE_CLASS = 18).
    let ok = unsafe {
        GetFileInformationByHandleEx(file.as_raw_handle(), 18,
            (&mut info as *mut FileIdInfo).cast(), std::mem::size_of::<FileIdInfo>() as u32)
    };
    if ok == 0 || info.file_id == [0; 16] { return None; }
    let id = info.file_id.iter().map(|b| format!("{b:02x}")).collect();
    Some((format!("{:016x}", info.volume_serial_number), id))
}

fn source_matches(a: &Value, b: &Value) -> bool {
    let keys = if b.get("windowsFileID").is_some() {
        ["windowsFileID", "windowsVolumeID", "size"]
    } else {
        ["inode", "volumeID", "size"]
    };
    keys.iter().all(|k| a.get(*k).is_some_and(|v| !v.is_null()) && a.get(*k) == b.get(*k))
}

fn read_json(p: &Path) -> Option<Value> {
    serde_json::from_slice(&fs::read(p).ok()?).ok()
}

/// Write whole: a temporary beside the target, then a rename.
pub fn write_atomic(target: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(dir) = target.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    let tmp = target.with_extension(format!("partial-{}", std::process::id()));
    fs::write(&tmp, bytes).map_err(|e| format!("{}: {e}", tmp.display()))?;
    fs::rename(&tmp, target).map_err(|e| format!("{}: {e}", target.display()))
}

pub struct SidecarStore {
    pub dir: PathBuf,
}

impl SidecarStore {
    pub fn path_for(&self, image: &Path) -> PathBuf {
        self.dir.join(sidecar_key(image))
    }

    /// The frame's sidecar, or `None` for a frame never edited. Recognises a
    /// moved file by its fingerprint and migrates a neighbour sidecar.
    pub fn load(&self, image: &Path) -> Option<Value> {
        let own = self.path_for(image);
        if let Some(v) = read_json(&own) {
            return Some(v);
        }
        // Moved or renamed: a sidecar whose remembered file is gone and whose
        // fingerprint is this file's.
        let wanted = identity(image);
        if wanted.get("inode").is_some() || wanted.get("windowsFileID").is_some() {
            if let Ok(rd) = fs::read_dir(&self.dir) {
                for d in rd.filter_map(Result::ok) {
                    let p = d.path();
                    if !p.to_string_lossy().ends_with(".spektra.json") {
                        continue;
                    }
                    let Some(mut v) = read_json(&p) else { continue };
                    let Some(src) = v.get("source").cloned() else { continue };
                    let remembered = src.get("path").and_then(Value::as_str).unwrap_or("");
                    if !remembered.is_empty() && !Path::new(remembered).exists() && source_matches(&src, &wanted) {
                        v["source"] = wanted.clone();
                        if self.save(image, &v).is_ok() && p != own {
                            let _ = fs::remove_file(&p);
                        }
                        return Some(v);
                    }
                }
            }
        }
        // The old home, beside the photograph: moved into the store.
        let neighbours = [
            image.with_file_name(format!(
                "{}.spektra.json",
                image.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
            )),
            image.with_extension("spektra.json"),
        ];
        for n in neighbours {
            if let Some(mut v) = read_json(&n) {
                v["source"] = wanted.clone();
                if self.save(image, &v).is_ok() {
                    let _ = fs::remove_file(&n);
                }
                return Some(v);
            }
        }
        None
    }

    pub fn save(&self, image: &Path, sidecar: &Value) -> Result<PathBuf, String> {
        let mut v = sidecar.clone();
        v["source"] = identity(image);
        let target = self.path_for(image);
        let bytes = serde_json::to_vec_pretty(&v).map_err(|e| e.to_string())?;
        write_atomic(&target, &bytes)?;
        Ok(target)
    }

    pub fn remove(&self, image: &Path) -> Result<(), String> {
        let p = self.path_for(image);
        if p.exists() {
            fs::remove_file(&p).map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_is_name_and_sixteen_hex() {
        // Use an absolute native path: a POSIX root on Windows inherits the
        // current drive, and PathBuf serializes it with backslashes.
        #[cfg(windows)]
        let (input, expected) = (r"C:\photos\a\..\b\DSC_0001.NEF", r"C:\photos\b\DSC_0001.NEF");
        #[cfg(not(windows))]
        let (input, expected) = ("/photos/a/../b/DSC_0001.NEF", "/photos/b/DSC_0001.NEF");
        let k = sidecar_key(Path::new(input));
        assert!(k.starts_with("DSC_0001.NEF-"));
        assert!(k.ends_with(".spektra.json"));
        let hex = &k["DSC_0001.NEF-".len()..k.len() - ".spektra.json".len()];
        assert_eq!(hex.len(), 16);
        // `..` resolved: the same key as the standardized path.
        assert_eq!(k, sidecar_key(Path::new(expected)));
        // Hash the explicit expected path, independently of standardized().
        let d = Sha256::digest(expected.as_bytes());
        let want: String = d.iter().take(8).map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, want);
    }

    #[test]
    fn save_load_and_neighbour_migration() {
        let root = std::env::temp_dir().join(format!("spk-sidecar-test-{}", std::process::id()));
        let photos = root.join("photos");
        fs::create_dir_all(&photos).unwrap();
        let img = photos.join("x.tif");
        fs::write(&img, b"not really a tiff").unwrap();
        let store = SidecarStore { dir: root.join("Sidecars") };
        assert!(store.load(&img).is_none());
        // A neighbour sidecar is migrated into the store.
        fs::write(photos.join("x.tif.spektra.json"), br#"{"schemaVersion":3,"params":{}}"#).unwrap();
        let v = store.load(&img).unwrap();
        assert_eq!(v["schemaVersion"], 3);
        assert!(!photos.join("x.tif.spektra.json").exists());
        assert!(store.path_for(&img).exists());
        // Moved: same inode, old path gone.
        let moved = photos.join("y.tif");
        fs::rename(&img, &moved).unwrap();
        #[cfg(any(unix, windows))]
        {
            let v = store.load(&moved).unwrap();
            assert_eq!(v["schemaVersion"], 3);
            assert!(store.path_for(&moved).exists());
            assert!(!store.path_for(&img).exists());
            assert_eq!(v["source"]["path"], standardized(&moved).display().to_string());
        }
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn identical_copy_does_not_inherit_moved_edits() {
        let root = std::env::temp_dir().join(format!("spk-file-id-test-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let original = root.join("原片.tif");
        let copy = root.join("副本.tif");
        fs::write(&original, b"same image bytes").unwrap();
        let store = SidecarStore { dir: root.join("Sidecars") };
        store.save(&original, &json!({"schemaVersion":3,"params":{"exposure":2}})).unwrap();
        fs::copy(&original, &copy).unwrap();
        let first = identity(&original);
        let second = identity(&copy);
        assert!(!source_matches(&first, &second));
        fs::remove_file(&original).unwrap();
        assert!(store.load(&copy).is_none());
        assert!(store.path_for(&original).exists());
        let moved = root.join("移动后.tif");
        store.save(&copy, &json!({"schemaVersion":3,"params":{"exposure":-1}})).unwrap();
        fs::rename(&copy, &moved).unwrap();
        assert_eq!(store.load(&moved).unwrap()["params"]["exposure"], -1);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn identity_requires_volume_file_and_size() {
        let original = json!({"windowsFileID":"001122", "windowsVolumeID":"aabb", "size":42});
        assert!(source_matches(&original, &original));
        for changed in [
            json!({"windowsFileID":"001122", "windowsVolumeID":"ccdd", "size":42}),
            json!({"windowsFileID":"001122", "windowsVolumeID":"aabb", "size":43}),
            json!({"windowsFileID":"different", "windowsVolumeID":"aabb", "size":42}),
            json!({"size":42}),
            json!({"inode":null,"volumeID":null,"size":42}),
        ] {
            assert!(!source_matches(&original, &changed));
        }
    }

    #[test]
    fn nested_photos_are_included_and_hidden_folders_skipped() {
        let root = std::env::temp_dir().join(format!("spk-nested-test-{}", std::process::id()));
        fs::create_dir_all(root.join("nested/deeper")).unwrap();
        fs::create_dir_all(root.join(".hidden")).unwrap();
        for p in ["A.ARW", "nested/B.NEF", "nested/deeper/C.JPG", ".hidden/no.png", "nested/no.txt"] {
            fs::write(root.join(p), b"fixture").unwrap();
        }
        let names: Vec<_> = list_images(&root).unwrap().into_iter().map(|e| e.name).collect();
        assert_eq!(names, vec!["A.ARW", "B.NEF", "C.JPG"]);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn image_filter() {
        assert!(is_image(Path::new("a/B.NEF")));
        assert!(is_image(Path::new("a/b.tiff")));
        assert!(!is_image(Path::new("a/b.xmp")));
        assert!(!is_image(Path::new("a/b.spektra.json")));
    }
}
