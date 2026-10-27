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
    "tif", "tiff", "jpg", "jpeg", "png", "spektrapair",
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

pub fn entry(p: &Path) -> Option<Entry> {
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

pub fn pair_load(path: &Path) -> Result<Value,String> {
    if path.extension().and_then(|s|s.to_str())!=Some("spektrapair") {return Err("not a half-frame pair file".into());}
    if fs::metadata(path).map_err(|e|e.to_string())?.len()>1024*1024 {return Err("pair JSON exceeds 1 MiB".into());}
    let value:Value=serde_json::from_slice(&fs::read(path).map_err(|e|e.to_string())?).map_err(|e|e.to_string())?;
    validate_pair(&value)?; Ok(value)
}
fn validate_pair(value:&Value)->Result<(),String> {
    if !value.is_object() || value.get("schemaVersion").and_then(Value::as_u64).unwrap_or(1)!=1 || !value.get("folder").map(Value::is_string).unwrap_or(false) {
        return Err("invalid half-frame pair document".into());
    }
    for side in ["left","right"] {
        if let Some(h)=value.get(side).filter(|v|!v.is_null()) {
            let p=h.get("path").and_then(Value::as_str).ok_or("a pair hole needs a path")?;
            if !Path::new(p).is_absolute() || p.to_ascii_lowercase().ends_with(".spektrapair") {return Err("a pair hole needs an absolute photograph path".into());}
        }
    } Ok(())
}
pub fn pair_save(path:&Path,value:&Value)->Result<(),String> {
    if !path.is_absolute() || path.extension().and_then(|s|s.to_str())!=Some("spektrapair") {return Err("only absolute .spektrapair recipes can be saved".into());}
    validate_pair(value)?;
    let bytes=serde_json::to_vec_pretty(value).map_err(|e|e.to_string())?;
    if bytes.len()>1024*1024 {return Err("pair JSON exceeds 1 MiB".into());}
    write_atomic(path,&bytes)
}
pub fn stored_pairs(store:&Path,folder:&Path)->Vec<Entry> {
    let wanted=standardized(folder);
    let Ok(entries)=fs::read_dir(store) else{return Vec::new()};
    entries.filter_map(Result::ok).filter_map(|e| {
        let path=e.path(); let value=pair_load(&path).ok()?;
        let f=PathBuf::from(value.get("folder")?.as_str()?);
        if standardized(&f)!=wanted {return None;} entry(&path)
    }).collect()
}
pub fn pair_create(store:&Path,folder:&Path,value:&Value)->Result<Entry,String> {
    static CREATE: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _guard=CREATE.lock().map_err(|_|"pair creation lock failed")?;
    let mut value=value.clone(); value["folder"]=json!(standardized(folder).display().to_string());
    validate_pair(&value)?;
    let digest=Sha256::digest(standardized(folder).to_string_lossy().as_bytes());
    let tag:String=digest.iter().take(3).map(|b|format!("{b:02x}")).collect();
    for n in 1..100000 {
        let p=store.join(format!("Half-Frame Pair {n} {tag}.spektrapair"));
        if p.exists() {continue;}
        pair_save(&p,&value)?; return entry(&p).ok_or("saved pair is unreadable".into());
    } Err("too many pairs in this folder".into())
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
        #[cfg(windows)]
        let (input, canonical) = (r"C:\photos\a\..\b\DSC_0001.NEF", r"C:\photos\b\DSC_0001.NEF");
        #[cfg(not(windows))]
        let (input, canonical) = ("/photos/a/../b/DSC_0001.NEF", "/photos/b/DSC_0001.NEF");
        let k = sidecar_key(Path::new(input));
        assert!(k.starts_with("DSC_0001.NEF-"));
        assert!(k.ends_with(".spektra.json"));
        let hex = &k["DSC_0001.NEF-".len()..k.len() - ".spektra.json".len()];
        assert_eq!(hex.len(), 16);
        // `..` resolved: the same key as the standardized path.
        assert_eq!(k, sidecar_key(Path::new(canonical)));
        // Hash an independent literal, with the native platform's separators.
        let d = Sha256::digest(canonical.as_bytes());
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
    fn image_filter() {
        assert!(is_image(Path::new("a/B.NEF")));
        assert!(is_image(Path::new("a/b.tiff")));
        assert!(!is_image(Path::new("a/b.xmp")));
        assert!(!is_image(Path::new("a/b.spektra.json")));
        assert!(is_image(Path::new("a/b.spektrapair")));
    }

    #[test]
    fn pairs_are_atomic_isolated_recipes_and_never_overwrite_photographs() {
        let stamp=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let root=std::env::temp_dir().join(format!("spk-pair-store-{}-{stamp}",std::process::id()));
        fs::create_dir(&root).unwrap(); let photos=root.join("photos"); fs::create_dir(&photos).unwrap();
        let photo=photos.join("a.ARW"); fs::write(&photo,b"original input").unwrap();
        let value=json!({"schemaVersion":1,"folder":photos.display().to_string(),"left":{"path":photo.display().to_string()},"right":null,"future":"preserve"});
        let store=root.join("Pairs"); let first=pair_create(&store,&photos,&value).unwrap();
        let second=pair_create(&store,&photos,&value).unwrap(); assert_ne!(first.path,second.path);
        let mut loaded=pair_load(Path::new(&first.path)).unwrap(); assert_eq!(loaded["future"],"preserve");
        loaded["left"]["exposureEV"]=json!(1.25); pair_save(Path::new(&first.path),&loaded).unwrap();
        assert_eq!(pair_load(Path::new(&first.path)).unwrap()["left"]["exposureEV"],1.25);
        assert_eq!(stored_pairs(&store,&photos).len(),2); assert!(stored_pairs(&store,&root.join("other")).is_empty());
        assert!(pair_save(&photo,&loaded).is_err()); assert_eq!(fs::read(&photo).unwrap(),b"original input");
        loaded["left"]["path"]=json!(first.path); assert!(pair_save(Path::new(&second.path),&loaded).is_err());
        let canonical=root.canonicalize().unwrap(); assert!(canonical.starts_with(std::env::temp_dir().canonicalize().unwrap()));
        fs::remove_dir_all(canonical).unwrap();
    }
}
