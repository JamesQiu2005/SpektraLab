//! Bounded persistent display pictures. These bytes are NEVER decoded engine
//! input, negative-cache data, export input, or neutral-picker samples.
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, File, FileTimes, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_IMAGE: usize = 64 * 1024 * 1024;
const MAX_HEADER: usize = 1024 * 1024;
const DEFAULT_CAP: u64 = 16 * 1024 * 1024 * 1024;
static SERIAL: AtomicU64 = AtomicU64::new(0);
static IO: Mutex<()> = Mutex::new(());

pub struct FrameCache { pub dir: PathBuf }
fn plain(md: &fs::Metadata) -> bool {
    if md.file_type().is_symlink() { return false; }
    #[cfg(windows)]
    { use std::os::windows::fs::MetadataExt; if md.file_attributes() & 0x400 != 0 { return false; } }
    true
}
fn owned(name: &str) -> bool {
    name.len()==69 && name.ends_with(".spfc") && name[..64].bytes().all(|b| b.is_ascii_hexdigit())
}
fn digest(data: &[u8]) -> String { format!("{:x}", Sha256::digest(data)) }
fn ticks(time: SystemTime) -> String { time.duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos().to_string() }

/// Keys include current filesystem identity, never a stale frontend stat.
pub fn key(descriptor: &Value, engine: &str) -> Result<String,String> {
    let sources=descriptor["sources"].as_array().ok_or("Cache sources are missing")?;
    if sources.is_empty() || sources.len()>3 || engine.is_empty() { return Err("Invalid cache identity".into()); }
    if !matches!(descriptor["kind"].as_str(),Some("print"|"original")) { return Err("Invalid cache kind".into()); }
    let mut identities=Vec::new();
    for source in sources {
        let path=PathBuf::from(source.as_str().ok_or("Invalid cache source")?);
        if !path.is_absolute() { return Err("Cache sources must be absolute".into()); }
        let md=fs::metadata(&path).map_err(|e|e.to_string())?;
        if !md.is_file() { return Err("Cache source is not a file".into()); }
        identities.push(json!({"path":crate::files::standardized(&path),"size":md.len(),
            "modified":ticks(md.modified().map_err(|e|e.to_string())?),
            "created":md.created().ok().map(ticks),"identity":crate::files::identity(&path)}));
    }
    let bytes=serde_json::to_vec(&json!({"schema":1,"engine":engine,"sources":identities,
        "kind":descriptor["kind"],"configuration":descriptor["configuration"]})).map_err(|e|e.to_string())?;
    if bytes.len()>MAX_HEADER { return Err("Cache key exceeds limit".into()); }
    Ok(digest(&bytes))
}

fn valid_image(header: &Value, bytes: usize) -> bool {
    let image=&header["image"];
    let Some(w)=image["width"].as_u64() else{return false};
    let Some(h)=image["height"].as_u64() else{return false};
    let bpp=match image["format"].as_str(){Some("rgba8")=>4,Some("rgba16")=>8,_=>return false};
    w>0&&h>0&&w<=16384&&h<=16384&&w*h*bpp==bytes as u64&&bytes<=MAX_IMAGE
        &&matches!(image["colorSpace"].as_str(),Some("sRGB"|"Display P3"))
}

impl FrameCache {
    fn prepare(&self) -> Result<(),String> {
        if let Ok(md)=fs::symlink_metadata(&self.dir) { if !md.is_dir()||!plain(&md){return Err("Cache root must be a plain directory".into());} }
        fs::create_dir_all(&self.dir).map_err(|e|e.to_string())
    }
    fn cap(&self) -> u64 {
        let path=self.dir.join("settings.json");
        if !fs::symlink_metadata(&path).is_ok_and(|m|m.is_file()&&plain(&m)&&m.len()<4096){return DEFAULT_CAP;}
        fs::read(path).ok()
            .and_then(|b|serde_json::from_slice::<Value>(&b).ok())
            .and_then(|v|v["cap_bytes"].as_u64()).filter(|n|*n<=64*1024*1024*1024).unwrap_or(DEFAULT_CAP)
    }
    fn entries(&self)->Result<Vec<(PathBuf,u64,SystemTime)>,String>{
        self.prepare()?;let mut items=Vec::new();
        for e in fs::read_dir(&self.dir).map_err(|e|e.to_string())? {
            let e=e.map_err(|e|e.to_string())?;
            if !owned(&e.file_name().to_string_lossy()){continue;}
            let md=fs::symlink_metadata(e.path()).map_err(|e|e.to_string())?;
            if md.is_file()&&plain(&md){items.push((e.path(),md.len(),md.modified().unwrap_or(UNIX_EPOCH)));}
        }Ok(items)
    }
    fn trim(&self,cap:u64)->Result<(),String>{
        let mut items=self.entries()?;items.sort_by_key(|i|i.2);
        let mut bytes: u64=items.iter().map(|i|i.1).sum();
        for (path,size,_) in items { if bytes<=cap {break;} fs::remove_file(path).map_err(|e|e.to_string())?;bytes=bytes.saturating_sub(size); }
        Ok(())
    }
    pub fn status(&self)->Result<Value,String>{
        let _lock=IO.lock().map_err(|e|e.to_string())?;
        let entries=self.entries()?;
        Ok(json!({"cap_bytes":self.cap(),"bytes":entries.iter().map(|e|e.1).sum::<u64>(),"entries":entries.len(),"max_entry_bytes":MAX_IMAGE,"path":self.dir}))
    }
    pub fn configure(&self,cap:u64)->Result<(),String>{
        if cap>64*1024*1024*1024{return Err("Cache limit must be between 0 and 64 GiB".into());}
        let _lock=IO.lock().map_err(|e|e.to_string())?;self.prepare()?;
        self.atomic(&self.dir.join("settings.json"),&serde_json::to_vec(&json!({"cap_bytes":cap})).unwrap(),&[])?;
        self.trim(cap)
    }
    pub fn clear(&self)->Result<(),String>{
        let _lock=IO.lock().map_err(|e|e.to_string())?;self.trim(0)
    }
    fn atomic(&self,path:&Path,header:&[u8],payload:&[u8])->Result<(),String>{
        let temp=self.dir.join(format!(".frame-{}-{}.partial",std::process::id(),SERIAL.fetch_add(1,Ordering::Relaxed)));
        let result=(||{
            let mut f=OpenOptions::new().write(true).create_new(true).open(&temp).map_err(|e|e.to_string())?;
            f.write_all(header).and_then(|_|f.write_all(payload)).and_then(|_|f.sync_all()).map_err(|e|e.to_string())?;
            drop(f);fs::rename(&temp,path).map_err(|e|e.to_string())
        })();if result.is_err(){let _=fs::remove_file(temp);}result
    }
    pub fn store(&self,key:&str,metadata:&Value,payload:&[u8])->Result<bool,String>{
        if key.len()!=64||!key.bytes().all(|b|b.is_ascii_hexdigit()){return Err("Invalid cache key".into());}
        if !valid_image(metadata,payload.len()){return Ok(false);}
        let _lock=IO.lock().map_err(|e|e.to_string())?;self.prepare()?;let cap=self.cap();
        let h=serde_json::to_vec(&json!({"version":1,"key":key,"checksum":digest(payload),"metadata":metadata})).map_err(|e|e.to_string())?;
        if h.len()>MAX_HEADER || payload.len()as u64+h.len()as u64+12>cap{return Ok(false);}
        let mut head=Vec::with_capacity(h.len()+12);head.extend_from_slice(b"SPFC");head.extend_from_slice(&(h.len()as u32).to_le_bytes());
        head.extend_from_slice(&(payload.len()as u32).to_le_bytes());head.extend_from_slice(&h);
        let path=self.dir.join(format!("{key}.spfc"));
        if fs::symlink_metadata(&path).is_ok_and(|md|!plain(&md)){return Err("Cache entry is not a plain file".into());}
        self.atomic(&path,&head,payload)?;self.trim(cap)?;Ok(true)
    }
    pub fn load(&self,key:&str)->Result<Option<(Value,Vec<u8>)>,String>{
        if key.len()!=64||!key.bytes().all(|b|b.is_ascii_hexdigit()){return Err("Invalid cache key".into());}
        let _lock=IO.lock().map_err(|e|e.to_string())?;self.prepare()?;
        if self.cap()==0{return Ok(None);}
        let path=self.dir.join(format!("{key}.spfc"));
        let Ok(md)=fs::symlink_metadata(&path)else{return Ok(None)};
        if !md.is_file()||!plain(&md){return Ok(None);}
        let result=(||{
            if md.len()>MAX_IMAGE as u64+MAX_HEADER as u64+12{return Err("Oversize cache".to_string());}
            let mut f=OpenOptions::new().read(true).write(true).open(&path).map_err(|e|e.to_string())?;let mut head=[0u8;12];f.read_exact(&mut head).map_err(|e|e.to_string())?;
            if &head[..4]!=b"SPFC"{return Err("Cache magic".into());}
            let h=u32::from_le_bytes(head[4..8].try_into().unwrap())as usize;let p=u32::from_le_bytes(head[8..12].try_into().unwrap())as usize;
            if h>MAX_HEADER||p>MAX_IMAGE||md.len()!=(12+h+p)as u64{return Err("Cache bounds".into());}
            let mut header=vec![0;h];f.read_exact(&mut header).map_err(|e|e.to_string())?;
            let header:Value=serde_json::from_slice(&header).map_err(|e|e.to_string())?;
            if header["version"]!=1||header["key"]!=key||!valid_image(&header["metadata"],p){return Err("Cache schema".into());}
            let mut payload=vec![0;p];f.read_exact(&mut payload).map_err(|e|e.to_string())?;
            if header["checksum"].as_str()!=Some(digest(&payload).as_str()){return Err("Cache checksum".into());}
            let _=f.set_times(FileTimes::new().set_modified(SystemTime::now()));
            Ok((header["metadata"].clone(),payload))
        })();
        match result{Ok(v)=>Ok(Some(v)),Err(_)=>{let _=fs::remove_file(path);Ok(None)}}
    }
}

/// Fingerprint actual native code and every staged resource. The caller caches
/// this once per application launch; a new build cannot reuse old image data.
pub fn engine_fingerprint(program:&Path,resources:&Path)->Result<String,String>{
    fn walk(root:&Path,files:&mut Vec<PathBuf>)->Result<(),String>{
        for e in fs::read_dir(root).map_err(|e|e.to_string())?{
            let e=e.map_err(|e|e.to_string())?;let md=fs::symlink_metadata(e.path()).map_err(|e|e.to_string())?;
            if !plain(&md){return Err("Reparse resources cannot be fingerprinted".into());}
            if md.is_dir(){walk(&e.path(),files)?;}else if md.is_file(){files.push(e.path());}
        }Ok(())
    }
    let mut files=vec![program.to_path_buf()];walk(resources,&mut files)?;files.sort();
    let mut hash=Sha256::new();let mut chunk=[0u8;65536];
    for path in files {hash.update(path.to_string_lossy().as_bytes());let mut f=File::open(path).map_err(|e|e.to_string())?;
        loop{let n=f.read(&mut chunk).map_err(|e|e.to_string())?;if n==0{break;}hash.update(&chunk[..n]);}}
    Ok(format!("{:x}",hash.finalize()))
}

#[cfg(test)]mod tests{
    use super::*;
    #[test]fn persistence_eviction_corruption_and_source_identity(){
        let root=std::env::temp_dir().join(format!("spk-cache-test-{}-{}",std::process::id(),SERIAL.fetch_add(1,Ordering::Relaxed)));
        fs::create_dir_all(&root).unwrap();let cache=FrameCache{dir:root.join("cache")};
        let source=root.join("source.raw");fs::write(&source,b"source").unwrap();
        let d=json!({"kind":"print","sources":[source],"configuration":{"film":"a","display":"srgb"}});
        let a=key(&d,"engine-a").unwrap();assert_ne!(a,key(&d,"engine-b").unwrap());
        let metadata=json!({"image":{"width":2,"height":2,"format":"rgba16","colorSpace":"sRGB"},"geometry":{"rotation":0}});
        assert!(cache.store(&a,&metadata,&[17;32]).unwrap());
        let reopened=FrameCache{dir:cache.dir.clone()};assert_eq!(reopened.load(&a).unwrap().unwrap(),(metadata.clone(),vec![17;32]));
        fs::write(cache.dir.join("unrelated.txt"),b"keep").unwrap();
        fs::write(&source,b"source changed").unwrap();assert_ne!(a,key(&d,"engine-a").unwrap());
        fs::write(cache.dir.join(format!("{a}.spfc")),b"SPFC\xff\xff\xff\xff\xff\xff\xff\xff").unwrap();
        assert!(cache.load(&a).unwrap().is_none());assert!(!cache.dir.join(format!("{a}.spfc")).exists());
        cache.configure(600).unwrap();
        for i in 0..8{let k=digest(&[i]);cache.store(&k,&metadata,&[i;32]).unwrap();}
        assert!(cache.status().unwrap()["bytes"].as_u64().unwrap()<=600);
        cache.clear().unwrap();assert_eq!(cache.status().unwrap()["entries"],0);
        assert_eq!(fs::read(cache.dir.join("unrelated.txt")).unwrap(),b"keep");
        cache.configure(0).unwrap();assert!(!cache.store(&a,&metadata,&[1;32]).unwrap());
        assert!(cache.load("../escape").is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
