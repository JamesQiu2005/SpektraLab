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
    "3fr", "ari", "arw", "bay", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "iiq", "k25", "kdc", "mef",
    "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw", "x3f",
    // rasters
    "tif", "tiff", "jpg", "jpeg", "png",
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

fn entry(p: &Path) -> Option<Entry> {
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

/// The photographs directly in `dir`, by name (case-insensitive, natural
/// enough for camera numbering). Hidden files are skipped.
pub fn list_images(dir: &Path) -> Result<Vec<Entry>, String> {
    let rd = fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let mut out: Vec<Entry> = rd
        .filter_map(Result::ok)
        .map(|d| d.path())
        .filter(|p| p.is_file() && is_image(p))
        .filter(|p| !p.file_name().map(|n| n.to_string_lossy().starts_with('.')).unwrap_or(true))
        .filter_map(|p| entry(&p))
        .collect();
    out.sort_by_key(|e| e.name.to_lowercase());
    Ok(out)
}

/// Dropped or argv paths → photographs: files kept if they are images, a
/// directory expanded one level.
pub fn expand(paths: &[String]) -> Vec<Entry> {
    let mut out = Vec::new();
    for p in paths {
        let path = PathBuf::from(p);
        if path.is_dir() {
            if let Ok(mut v) = list_images(&path) {
                out.append(&mut v);
            }
        } else if path.is_file() && is_image(&path) {
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
    }
    v
}

fn source_matches(a: &Value, b: &Value) -> bool {
    let keys = ["inode", "volumeID", "size"];
    keys.iter().all(|k| a.get(*k).is_some() && a.get(*k) == b.get(*k))
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

/// The edits files that may sit beside a photograph: `<name.ext>.spektra.json`
/// (what `export_original` writes) and the old `<name>.spektra.json`.
fn neighbours(image: &Path) -> [PathBuf; 2] {
    let name = image.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    [image.with_file_name(format!("{name}.spektra.json")), image.with_extension("spektra.json")]
}

/// The edit fields that name a second photograph: a half-frame pair's other
/// half and a double exposure's second frame.
const SECOND_PHOTOS: [&str; 2] = ["pairWith", "doubleWith"];

/// `export_original` stores the second photograph by file name, beside the
/// first: make it a path in this photograph's folder again.
fn resolve_seconds(v: &mut Value, image: &Path) {
    let Some(dir) = image.parent() else { return };
    for key in SECOND_PHOTOS {
        let Some(name) = v["params"][key].as_str() else { continue };
        if !name.is_empty() && !name.contains('/') && !name.contains('\\') {
            v["params"][key] = json!(dir.join(name).display().to_string());
        }
    }
}

/// Copy whole: a temporary beside the target, then a rename.
fn copy_atomic(from: &Path, to: &Path) -> Result<(), String> {
    let tmp = to.with_extension(format!("partial-{}", std::process::id()));
    fs::copy(from, &tmp).map_err(|e| format!("{}: {e}", from.display()))?;
    fs::rename(&tmp, to).map_err(|e| format!("{}: {e}", to.display()))
}

/// "Original + edits": the photograph's own bytes as `dir/name`, untouched;
/// its edits beside it as `name.spektra.json` (without `source`, which the
/// receiving store writes for its own file); and a second photograph the edits
/// use (a half-frame pair, a double exposure), copied beside them and named by
/// its file name, which `SidecarStore::load` resolves against the folder.
/// Develop opens the copy with the edits on another computer or phone; other
/// apps see the original. Returns the files written, the photograph first.
pub fn export_original(
    store: &SidecarStore,
    image: &Path,
    dir: &Path,
    name: &str,
    overwrite: bool,
) -> Result<Vec<PathBuf>, String> {
    if !image.is_file() || !is_image(image) {
        return Err(format!("{} is not a photograph", image.display()));
    }
    if name.is_empty() || name.contains('/') || name.contains('\\') || !is_image(Path::new(name)) {
        return Err(format!("{name} is not a photograph's file name"));
    }
    fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let target = dir.join(name);
    if standardized(&target) == standardized(image) {
        return Err(format!("{} would replace the original", target.display()));
    }
    if target.exists() && !overwrite {
        return Err(format!("{} exists", target.display()));
    }
    copy_atomic(image, &target)?;
    let mut written = vec![target];
    let Some(mut v) = store.load(image) else { return Ok(written) }; // never edited: the original alone
    if let Some(o) = v.as_object_mut() {
        o.remove("source");
    }
    for key in SECOND_PHOTOS {
        let Some(second) = v["params"][key].as_str().filter(|s| !s.is_empty()).map(PathBuf::from) else { continue };
        if !second.is_file() {
            continue; // already missing here: left as it is
        }
        let file = second.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let (stem, ext) = match file.rfind('.') {
            Some(i) if i > 0 => (file[..i].to_string(), file[i..].to_string()),
            _ => (file.clone(), String::new()),
        };
        let size = fs::metadata(&second).map(|m| m.len()).ok();
        // The same photograph already there (an earlier export) is used as it is; another of that name is not.
        let mut to = dir.join(&file);
        let mut n = 2;
        while to.exists() && fs::metadata(&to).map(|m| m.len()).ok() != size {
            to = dir.join(format!("{stem}-{n}{ext}"));
            n += 1;
        }
        if !to.exists() {
            copy_atomic(&second, &to)?;
            written.push(to.clone());
        }
        v["params"][key] = json!(to.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default());
    }
    let side = dir.join(format!("{name}.spektra.json"));
    write_atomic(&side, &serde_json::to_vec_pretty(&v).map_err(|e| e.to_string())?)?;
    written.push(side);
    Ok(written)
}

pub struct SidecarStore {
    pub dir: PathBuf,
}

impl SidecarStore {
    pub fn path_for(&self, image: &Path) -> PathBuf {
        self.dir.join(sidecar_key(image))
    }

    /// The frame's sidecar, or `None` for a frame never edited. Takes in an
    /// edits file beside the photograph, recognises a moved file by its
    /// fingerprint.
    pub fn load(&self, image: &Path) -> Option<Value> {
        let own = self.path_for(image);
        let wanted = identity(image);
        // An edits file beside the photograph: an "Original + edits" export
        // from another computer or phone (`export_original`), or the old home
        // of sidecars. Moved into the store, unless the store's own is newer.
        let own_time = fs::metadata(&own).and_then(|m| m.modified()).ok();
        for n in neighbours(image) {
            let Ok(t) = fs::metadata(&n).and_then(|m| m.modified()) else { continue };
            if own_time.is_some_and(|o| o >= t) {
                continue;
            }
            if let Some(mut v) = read_json(&n) {
                v["source"] = wanted.clone();
                resolve_seconds(&mut v, image);
                if self.save(image, &v).is_ok() {
                    let _ = fs::remove_file(&n);
                }
                return Some(v);
            }
        }
        if let Some(v) = read_json(&own) {
            return Some(v);
        }
        // Moved or renamed: a sidecar whose remembered file is gone and whose
        // fingerprint is this file's.
        if wanted.get("inode").is_some() {
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
        let k = sidecar_key(Path::new("/photos/a/../b/DSC_0001.NEF"));
        assert!(k.starts_with("DSC_0001.NEF-"));
        assert!(k.ends_with(".spektra.json"));
        let hex = &k["DSC_0001.NEF-".len()..k.len() - ".spektra.json".len()];
        assert_eq!(hex.len(), 16);
        // `..` resolved: the same key as the standardized path.
        assert_eq!(k, sidecar_key(Path::new("/photos/b/DSC_0001.NEF")));
        // sha256("/photos/b/DSC_0001.NEF")[:16], computed independently.
        let d = Sha256::digest(b"/photos/b/DSC_0001.NEF");
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
        #[cfg(unix)]
        {
            let v = store.load(&moved).unwrap();
            assert_eq!(v["schemaVersion"], 3);
            assert!(store.path_for(&moved).exists());
        }
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn original_and_edits_round_trip() {
        let root = std::env::temp_dir().join(format!("spk-original-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let photos = root.join("photos");
        fs::create_dir_all(&photos).unwrap();
        let img = photos.join("A.ARW");
        let half = photos.join("B.ARW");
        fs::write(&img, b"raw bytes A").unwrap();
        fs::write(&half, b"raw bytes B").unwrap();
        let here = SidecarStore { dir: root.join("Sidecars") };
        // Never edited: the original alone.
        let out = root.join("out");
        let w = export_original(&here, &img, &out, "A.ARW", false).unwrap();
        assert_eq!(w, vec![out.join("A.ARW")]);
        assert_eq!(fs::read(out.join("A.ARW")).unwrap(), b"raw bytes A");
        // Edited, paired with B: the original, B and the edits; B named by file name.
        let edits = json!({"schemaVersion": 3, "params": {"filmStock": "kodak_portra_400", "pairWith": half.display().to_string()}});
        here.save(&img, &edits).unwrap();
        assert!(export_original(&here, &img, &out, "A.ARW", false).is_err()); // exists, no overwrite
        let w = export_original(&here, &img, &out, "A.ARW", true).unwrap();
        assert_eq!(w, vec![out.join("A.ARW"), out.join("B.ARW"), out.join("A.ARW.spektra.json")]);
        let side = read_json(&out.join("A.ARW.spektra.json")).unwrap();
        assert_eq!(side["params"]["pairWith"], "B.ARW");
        assert!(side.get("source").is_none());
        // Never the original itself.
        assert!(export_original(&here, &img, &photos, "A.ARW", true).is_err());
        // "Another device": a fresh store opens the copy with the edits, B found beside it.
        let there = SidecarStore { dir: root.join("Sidecars2") };
        let v = there.load(&out.join("A.ARW")).unwrap();
        assert_eq!(v["params"]["filmStock"], "kodak_portra_400");
        assert_eq!(v["params"]["pairWith"], out.join("B.ARW").display().to_string());
        assert!(!out.join("A.ARW.spektra.json").exists()); // taken into the store
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_newer_edits_file_beside_the_photo_wins() {
        let root = std::env::temp_dir().join(format!("spk-newer-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let img = root.join("x.dng");
        fs::write(&img, b"raw").unwrap();
        let store = SidecarStore { dir: root.join("Sidecars") };
        store.save(&img, &json!({"schemaVersion": 3, "params": {"filmStock": "old"}})).unwrap();
        let beside = root.join("x.dng.spektra.json");
        // Older than the store's own: ignored and left alone.
        fs::write(&beside, br#"{"schemaVersion":3,"params":{"filmStock":"stale"}}"#).unwrap();
        let past = std::time::SystemTime::now() - std::time::Duration::from_secs(3600);
        fs::File::options().write(true).open(&beside).unwrap().set_modified(past).unwrap();
        assert_eq!(store.load(&img).unwrap()["params"]["filmStock"], "old");
        assert!(beside.exists());
        // Newer: it replaces the store's.
        fs::write(&beside, br#"{"schemaVersion":3,"params":{"filmStock":"new"}}"#).unwrap();
        let future = std::time::SystemTime::now() + std::time::Duration::from_secs(3600);
        fs::File::options().write(true).open(&beside).unwrap().set_modified(future).unwrap();
        assert_eq!(store.load(&img).unwrap()["params"]["filmStock"], "new");
        assert!(!beside.exists());
        assert_eq!(store.load(&img).unwrap()["params"]["filmStock"], "new");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn image_filter() {
        assert!(is_image(Path::new("a/B.NEF")));
        assert!(is_image(Path::new("a/b.tiff")));
        assert!(!is_image(Path::new("a/b.xmp")));
        assert!(!is_image(Path::new("a/b.spektra.json")));
    }
}
