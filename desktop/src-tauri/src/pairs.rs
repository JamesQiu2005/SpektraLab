//! Half-frame documents live in the application's store, never beside a RAW.
//! Image paths are references only. Opening a document elsewhere is read-only;
//! creating, replacing or removing a document is confined to Sidecars/Pairs.
use crate::files::{entry, is_image, standardized, Entry};
use serde_json::Value;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

const MAX_BYTES: u64 = 1024 * 1024;
static WRITES: Mutex<()> = Mutex::new(());
static SERIAL: AtomicU64 = AtomicU64::new(0);

pub fn is_pair(p: &Path) -> bool {
    p.extension().and_then(|e| e.to_str()).is_some_and(|e| e.eq_ignore_ascii_case("spektrapair"))
}

fn same_path(a: &Path, b: &Path) -> bool {
    let a = standardized(a); let b = standardized(b);
    #[cfg(windows)]
    { a.to_string_lossy().to_lowercase() == b.to_string_lossy().to_lowercase() }
    #[cfg(not(windows))]
    { a == b }
}

fn plain_file(md: &fs::Metadata) -> bool {
    if md.file_type().is_symlink() { return false; }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if md.file_attributes() & 0x400 != 0 { return false; }
    }
    true
}

fn bounded(v: &Value, key: &str, lo: f64, hi: f64) -> Result<(), String> {
    if let Some(n) = v.get(key) {
        if !n.as_f64().is_some_and(|n| n.is_finite() && n >= lo && n <= hi) {
            return Err(format!("Pair {key} must be between {lo} and {hi}"));
        }
    }
    Ok(())
}

fn validate(value: &Value) -> Result<&str, String> {
    if !value.is_object() || value.get("schemaVersion").is_some_and(|n| n.as_u64() != Some(1)) {
        return Err("Unsupported half-frame document version".into());
    }
    let folder = value.get("folder").and_then(Value::as_str).ok_or("Pair folder is missing")?;
    if !Path::new(folder).is_absolute() { return Err("Pair folder must be absolute".into()); }
    bounded(value, "spacingMM", 0.5, 2.0)?;
    for key in ["onStrip", "turned"] {
        if value.get(key).is_some_and(|v| !v.is_boolean()) { return Err(format!("Pair {key} must be boolean")); }
    }
    for side in ["left", "right"] {
        let Some(hole) = value.get(side).filter(|v| !v.is_null()) else { continue; };
        let source = hole.get("path").and_then(Value::as_str).ok_or("Pair source path is missing")?;
        if !Path::new(source).is_absolute() || !is_image(Path::new(source)) {
            return Err("Pair sources must be absolute photograph paths; nested pairs are not supported".into());
        }
        bounded(hole, "exposureEV", -5.0, 5.0)?;
        if let Some(p) = hole.get("placement") {
            if !p.is_object() { return Err("Pair placement must be an object".into()); }
            bounded(p,"scale",1.0,4.0)?; bounded(p,"x",-1.0,1.0)?; bounded(p,"y",-1.0,1.0)?;
            if p.get("quarterTurns").is_some_and(|v| v.as_i64().is_none()) { return Err("Pair quarterTurns must be an integer".into()); }
        }
        for key in ["printScope", "exposureScope"] {
            if hole.get(key).is_some_and(|v| !matches!(v.as_str(), Some("frame" | "film"))) {
                return Err(format!("Pair {key} must be frame or film"));
            }
        }
    }
    Ok(folder)
}

pub struct PairStore { pub dir: PathBuf }

impl PairStore {
    fn checked_target(&self, path: &Path) -> Result<PathBuf, String> {
        let path = standardized(path);
        if !is_pair(&path) || !path.parent().is_some_and(|p| same_path(p, &self.dir)) {
            return Err("Half-frame writes are restricted to the application's Pairs store".into());
        }
        fs::create_dir_all(&self.dir).map_err(|e| e.to_string())?;
        let root = fs::symlink_metadata(&self.dir).map_err(|e| e.to_string())?;
        if !root.is_dir() || !plain_file(&root) { return Err("Pair store must be a regular directory".into()); }
        if let Ok(md) = fs::symlink_metadata(&path) {
            if !md.is_file() || !plain_file(&md) { return Err("Pair target must be a regular file".into()); }
        }
        Ok(path)
    }

    pub fn load(path: &Path) -> Result<Option<Value>, String> {
        if !is_pair(path) { return Err("Expected a .spektrapair document".into()); }
        let mut file = match fs::File::open(path) {
            Ok(f) => f,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.to_string()),
        };
        if file.metadata().map_err(|e| e.to_string())?.len() > MAX_BYTES { return Err("Half-frame document is too large".into()); }
        let mut bytes = Vec::new();
        (&mut file).take(MAX_BYTES + 1).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
        if bytes.len() as u64 > MAX_BYTES { return Err("Half-frame document is too large".into()); }
        let value = serde_json::from_slice(&bytes).map_err(|e| format!("Invalid half-frame document: {e}"))?;
        validate(&value)?;
        Ok(Some(value))
    }

    pub fn save(&self, path: &Path, value: &Value) -> Result<(), String> {
        validate(value)?;
        let bytes = serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?;
        if bytes.len() as u64 > MAX_BYTES { return Err("Half-frame document is too large".into()); }
        let _guard = WRITES.lock().map_err(|_| "Pair store lock failed")?;
        let target = self.checked_target(path)?;
        let temporary = target.with_extension(format!("partial-{}-{}",std::process::id(),SERIAL.fetch_add(1,Ordering::Relaxed)));
        let result = (|| {
            let mut file = fs::OpenOptions::new().write(true).create_new(true).open(&temporary).map_err(|e| e.to_string())?;
            file.write_all(&bytes).and_then(|_| file.sync_all()).map_err(|e| e.to_string())?;
            drop(file);
            fs::rename(&temporary,&target).map_err(|e| e.to_string())
        })();
        if result.is_err() { let _ = fs::remove_file(&temporary); }
        result
    }

    pub fn create(&self, folder: &Path, value: &Value) -> Result<Entry,String> {
        let declared = validate(value)?;
        if !folder.is_absolute() || !same_path(folder,Path::new(declared)) { return Err("Pair folder does not match its document".into()); }
        let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(|e| e.to_string())?.as_nanos();
        let id = SERIAL.fetch_add(1,Ordering::Relaxed);
        let path = self.dir.join(format!("Pair-{stamp}-{}-{id}.spektrapair",std::process::id()));
        if path.exists() { return Err("Pair document already exists".into()); }
        self.save(&path,value)?;
        entry(&path).ok_or_else(|| "Cannot inspect saved half-frame document".into())
    }

    pub fn list(&self, folder: &Path) -> Result<Vec<Entry>,String> {
        let mut out=Vec::new();
        let directory=match fs::read_dir(&self.dir) {
            Ok(d)=>d, Err(e) if e.kind()==std::io::ErrorKind::NotFound=>return Ok(out), Err(e)=>return Err(e.to_string()),
        };
        for file in directory {
            let file=file.map_err(|e|e.to_string())?;
            let path=file.path();
            if !is_pair(&path) || !file.file_type().map_err(|e|e.to_string())?.is_file() { continue; }
            let Ok(Some(value))=Self::load(&path) else { continue; };
            if same_path(folder,Path::new(value["folder"].as_str().unwrap())) {
                if let Some(e)=entry(&path) {out.push(e);}
            }
        }
        out.sort_by(|a,b|a.path.cmp(&b.path));Ok(out)
    }

    pub fn delete(&self, path: &Path) -> Result<(),String> {
        let _guard=WRITES.lock().map_err(|_|"Pair store lock failed")?;
        let path=self.checked_target(path)?;
        match fs::remove_file(path) { Ok(())=>Ok(()),Err(e) if e.kind()==std::io::ErrorKind::NotFound=>Ok(()),Err(e)=>Err(e.to_string()) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn pair_roundtrip_and_storage_boundaries() {
        let root=std::env::temp_dir().join(format!("spk-pairs-{}",std::process::id()));
        let photos=root.join("照片");fs::create_dir_all(&photos).unwrap();
        let raw=photos.join("原片.ARW");fs::write(&raw,b"source stays untouched").unwrap();
        let store=PairStore{dir:root.join("Sidecars/Pairs")};
        let mut value=json!({"schemaVersion":1,"folder":photos,"left":{"path":raw},"right":null,"spacingMM":1});
        let created=store.create(&photos,&value).unwrap();let path=Path::new(&created.path);
        assert_eq!(PairStore::load(path).unwrap(),Some(value.clone()));
        value["left"]["exposureEV"]=json!(2);store.save(path,&value).unwrap();
        assert_eq!(PairStore::load(path).unwrap().unwrap()["left"]["exposureEV"],2);
        assert_eq!(store.list(&photos).unwrap().len(),1);
        assert!(store.list(&photos.join("child")).unwrap().is_empty());
        assert!(store.create(&root,&value).is_err());
        assert!(store.save(&raw,&value).is_err());assert!(store.delete(&raw).is_err());
        let external=photos.join("external.spektrapair");
        assert!(store.save(&external,&value).is_err());assert!(store.delete(&external).is_err());
        let mut invalid=value.clone();invalid["left"]["path"]=json!(path);assert!(store.save(path,&invalid).is_err());
        invalid=value.clone();invalid["spacingMM"]=json!(10);assert!(store.save(path,&invalid).is_err());
        invalid=value.clone();invalid["schemaVersion"]=json!(2);assert!(store.save(path,&invalid).is_err());
        invalid=value.clone();invalid["left"]["placement"]=json!({"scale":0});assert!(store.save(path,&invalid).is_err());
        assert_eq!(PairStore::load(path).unwrap(),Some(value.clone()));
        assert_eq!(crate::files::expand(&[created.path.clone()]).len(),1);
        assert_eq!(fs::read(&raw).unwrap(),b"source stays untouched");
        store.delete(path).unwrap();assert_eq!(PairStore::load(path).unwrap(),None);
        fs::write(store.dir.join("corrupt.spektrapair"),b"{").unwrap();
        assert!(store.list(&photos).unwrap().is_empty());
        fs::remove_dir_all(root).unwrap();
    }
}
