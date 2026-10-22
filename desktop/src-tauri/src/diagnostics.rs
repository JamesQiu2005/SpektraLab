//! User-controlled diagnostics. Cleanup only touches owned regular log files,
//! never a photograph, symlink or the active session; bundles are bounded ZIPs.
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Manager, State};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub level: String, pub per_node: bool, pub export_job_log: bool,
    pub days: u32, pub megabytes: u64, pub files: usize, pub directory: Option<PathBuf>,
}
impl Default for Config {
    fn default() -> Self { Self { level: "info".into(), per_node: false, export_job_log: false,
        days: 7, megabytes: 100, files: 20, directory: None } }
}
impl Config {
    fn validate(&self) -> Result<(), String> {
        if !matches!(self.level.as_str(), "error" | "info" | "debug") || !(1..=365).contains(&self.days)
            || !(10..=10_000).contains(&self.megabytes) || !(1..=500).contains(&self.files)
            || self.directory.as_ref().is_some_and(|p| !p.is_absolute()) {
            return Err("Invalid diagnostic settings".into());
        }
        if self.per_node && self.level=="error" {return Err("Per-node timings require Normal or Debug logging.".into());}
        if let Some(dir)=&self.directory { reject_link_directory(dir)?; }
        Ok(())
    }
    fn filter(&self) -> log::LevelFilter { match self.level.as_str() { "error" => log::LevelFilter::Error, "debug" => log::LevelFilter::Debug, _ => log::LevelFilter::Info } }
}
pub struct Diagnostics {
    pub config: Mutex<Config>, config_path: PathBuf,
    pub directory: PathBuf, pub prefix: String, pub cleanup_error: Mutex<Option<String>>,
    pub previous_session: Value, marker: PathBuf,
}
fn stamp() -> u128 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() }
fn regular(path: &Path) -> Option<fs::Metadata> {
    let md = fs::symlink_metadata(path).ok()?;
    if !md.is_file() || md.file_type().is_symlink() { return None; }
    #[cfg(windows)] { use std::os::windows::fs::MetadataExt; if md.file_attributes() & 0x400 != 0 { return None; } }
    Some(md)
}
fn reject_link_directory(path:&Path)->Result<(),String> {
    if let Ok(md)=fs::symlink_metadata(path) {
        if md.file_type().is_symlink(){return Err("Log directory must not be a symbolic link.".into());}
        #[cfg(windows)] {use std::os::windows::fs::MetadataExt;if md.file_attributes()&0x400!=0{return Err("Log directory must not be a junction or reparse point.".into());}}
        if !md.is_dir(){return Err("Log directory is not a directory.".into());}
    }
    Ok(())
}
fn log_files(dir: &Path) -> Vec<(PathBuf, fs::Metadata)> {
    let mut files = Vec::new();
    if let Ok(rd) = fs::read_dir(dir) { for e in rd.flatten() {
        let p = e.path(); let name = e.file_name().to_string_lossy().to_lowercase();
        let stem=name.strip_suffix(".log").unwrap_or("");
        let generated=stem.strip_prefix("spektralab-").is_some_and(|s| {
            let base=s.split('_').next().unwrap_or(""); let parts:Vec<_>=base.split('-').collect();
            parts.len()==2 && parts.iter().all(|v|!v.is_empty() && v.bytes().all(|c|c.is_ascii_digit()))
        });
        let legacy=stem=="spektralab" || stem.strip_prefix("spektralab_").is_some_and(|s|!s.is_empty() && s.bytes().all(|c|c.is_ascii_digit()||b"-_:T".contains(&c)));
        if generated || legacy {
            if let Some(md) = regular(&p) { files.push((p, md)); }
        }
    } }
    files.sort_by_key(|(_, m)| std::cmp::Reverse(m.modified().unwrap_or(UNIX_EPOCH)));
    files
}
fn clean(dir: &Path, config: &Config, keeping: &str, clear: bool) -> Result<usize, String> {
    reject_link_directory(dir)?;
    let current=if keeping.is_empty(){None}else{regular(&dir.join(keeping))};
    let mut bytes = current.as_ref().map(|m|m.len()).unwrap_or(0); let mut count = usize::from(current.is_some()); let mut removed = 0;
    let now = SystemTime::now();
    for (path, md) in log_files(dir) {
        if !keeping.is_empty() && path.file_name().unwrap().to_string_lossy()==keeping { continue; }
        let old = now.duration_since(md.modified().unwrap_or(UNIX_EPOCH)).unwrap_or_default() > Duration::from_secs(u64::from(config.days) * 86400);
        count += 1; bytes += md.len();
        if clear || old || count > config.files || bytes > config.megabytes * 1_000_000 {
            fs::remove_file(&path).map_err(|e| format!("Could not remove {}: {e}", path.display()))?; removed += 1;
        }
    }
    Ok(removed)
}
pub fn initialize(app: &AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let data = app.path().app_data_dir()?; fs::create_dir_all(&data)?;
    let config_path = data.join("diagnostics.json");
    let config: Config = fs::read(&config_path).ok().and_then(|b| serde_json::from_slice(&b).ok())
        .filter(|c: &Config| c.validate().is_ok()).unwrap_or_default();
    let fallback = app.path().app_log_dir()?;
    let mut directory = config.directory.clone().unwrap_or_else(|| fallback.clone());
    let mut failure = None;
    let writable=(||->std::io::Result<()>{fs::create_dir_all(&directory)?;let p=directory.join(format!(".spk-log-probe-{}-{}",std::process::id(),stamp()));
        let f=OpenOptions::new().write(true).create_new(true).open(&p)?;drop(f);fs::remove_file(p)})();
    if let Err(e) = writable { failure = Some(format!("Log directory unavailable: {e}; using the default folder.")); directory = fallback; fs::create_dir_all(&directory)?; }
    let prefix = format!("spektralab-{}-{}", stamp(), std::process::id());
    if let Err(e) = clean(&directory, &config, "", false) { failure = Some(e); }
    let marker = data.join("diagnostic-session.json");
    let previous_session = fs::read(&marker).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()).unwrap_or(Value::Null);
    let _ = crate::files::write_atomic(&marker, &serde_json::to_vec(&json!({"started_ms":stamp(),"clean_exit":false})).unwrap());
    app.plugin(tauri_plugin_log::Builder::new().targets([
        tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::Stdout),
        tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::Folder { path: directory.clone(), file_name: Some(prefix.clone()) })
    ]).max_file_size(4 * 1024 * 1024).rotation_strategy(tauri_plugin_log::RotationStrategy::KeepAll)
      .level(log::LevelFilter::Trace).build())?;
    log::set_max_level(config.filter());
    app.manage(Diagnostics { config: Mutex::new(config), config_path, directory, prefix,
        cleanup_error: Mutex::new(failure), previous_session, marker });
    let handle=app.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(60)).await;
            if handle.get_webview_window("main").is_none(){break;}
            if handle.try_state::<crate::AppState>().is_some_and(|s|s.host.is_busy()){continue;}
            let app=handle.clone();
            let _=tauri::async_runtime::spawn_blocking(move || {let d=app.state::<Diagnostics>();
                let result=clean(&d.directory,&d.config.lock().unwrap(),&format!("{}.log",d.prefix),false);
                *d.cleanup_error.lock().unwrap()=result.err();}).await;
        }
    });
    Ok(())
}
pub fn clean_exit(app: &AppHandle) {
    if let Some(d) = app.try_state::<Diagnostics>() { let _ = crate::files::write_atomic(&d.marker,
        &serde_json::to_vec(&json!({"ended_ms":stamp(),"clean_exit":true})).unwrap()); }
}
pub fn configuration(app: &AppHandle) -> Config {
    app.try_state::<Diagnostics>().map(|d| d.config.lock().unwrap().clone()).unwrap_or_default()
}
fn status(d: &Diagnostics) -> Value {
    json!({"settings":d.config.lock().unwrap().clone(),"directory":d.directory,
      "cleanup_error":d.cleanup_error.lock().unwrap().clone(),"previous_session":d.previous_session})
}
#[tauri::command]
pub fn diagnostics_get(d: State<'_, Diagnostics>) -> Value { status(&d) }
#[tauri::command]
pub fn diagnostics_set(d: State<'_, Diagnostics>, settings: Config) -> Result<Value, String> {
    settings.validate()?;
    crate::files::write_atomic(&d.config_path, &serde_json::to_vec(&settings).map_err(|e|e.to_string())?)?;
    log::set_max_level(settings.filter()); *d.config.lock().unwrap() = settings;
    *d.cleanup_error.lock().unwrap()=clean(&d.directory,&d.config.lock().unwrap(),&format!("{}.log",d.prefix),false).err(); Ok(status(&d))
}
#[tauri::command]
pub fn diagnostics_clear_logs(d: State<'_, Diagnostics>) -> Result<usize, String> {
    let result = clean(&d.directory, &d.config.lock().unwrap(), &format!("{}.log",d.prefix), true);
    *d.cleanup_error.lock().unwrap() = result.as_ref().err().cloned(); result
}

// Unstructured host stderr may contain arbitrary path quoting. Conservatively
// omit the entire record when names are disabled instead of a partial redaction.
fn redact_logs(text: &str) -> String {
    const EXT: &[&str] = &[".arw", ".nef", ".nrw", ".cr2", ".cr3", ".crw", ".raf", ".dng", ".rw2", ".orf", ".pef", ".iiq", ".3fr", ".srw", ".x3f", ".jpg", ".jpeg", ".png", ".tif", ".exr", ".heic", ".heif", ".avif", ".webp", ".spektrapair", ".spektra"];
    text.lines().map(|line| {
        let low = line.to_lowercase();
        if line.contains(":\\") || line.contains(":/") || line.contains("\\\\") || line.contains(" /") || line.contains("\"/") || line.contains("'/") || line.starts_with('/') || EXT.iter().any(|e|low.contains(e)) {
            "[record containing a local path or image name omitted]\n".to_owned()
        } else { format!("{line}\n") }
    }).collect()
}
fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &b in bytes { crc ^= u32::from(b); for _ in 0..8 { crc = (crc >> 1) ^ (0xedb88320u32 & 0u32.wrapping_sub(crc & 1)); } }
    !crc
}
fn u16le(out: &mut Vec<u8>, n: u16) { out.extend(n.to_le_bytes()); }
fn u32le(out: &mut Vec<u8>, n: u32) { out.extend(n.to_le_bytes()); }
fn zip(entries: &[(String, Vec<u8>)]) -> Vec<u8> {
    let mut out = Vec::new(); let mut central = Vec::new();
    for (name, data) in entries {
        let offset = out.len() as u32; let crc = crc32(data); let size = data.len() as u32;
        u32le(&mut out, 0x04034b50); for n in [20,0x800,0,0,33] {u16le(&mut out,n);}
        for n in [crc,size,size] {u32le(&mut out,n);} u16le(&mut out,name.len() as u16); u16le(&mut out,0); out.extend(name.as_bytes()); out.extend(data);
        u32le(&mut central,0x02014b50); for n in [20,20,0x800,0,0,33] {u16le(&mut central,n);}
        for n in [crc,size,size] {u32le(&mut central,n);} u16le(&mut central,name.len() as u16);
        for _ in 0..4 {u16le(&mut central,0);} u32le(&mut central,0); u32le(&mut central,offset); central.extend(name.as_bytes());
    }
    let start=out.len() as u32; let len=central.len() as u32; out.extend(central); u32le(&mut out,0x06054b50);
    for n in [0,0,entries.len() as u16,entries.len() as u16] {u16le(&mut out,n);}
    u32le(&mut out,len);u32le(&mut out,start);u16le(&mut out,0);out
}
fn create_whole(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if path.exists() { return Err("The destination already exists; choose another file name.".into()); }
    static SERIAL:std::sync::atomic::AtomicU64=std::sync::atomic::AtomicU64::new(0);
    let serial=SERIAL.fetch_add(1,std::sync::atomic::Ordering::Relaxed);
    let tmp=path.with_extension(format!("partial-{}-{}-{serial}",std::process::id(),stamp()));
    let mut created=false;
    let result=(||->std::io::Result<()>{ let mut f=OpenOptions::new().write(true).create_new(true).open(&tmp)?;created=true; f.write_all(bytes)?;f.sync_all()?; drop(f);
        #[cfg(windows)] {
            use std::os::windows::ffi::OsStrExt;
            #[link(name="kernel32")] extern "system" { fn MoveFileW(from: *const u16, to: *const u16) -> i32; }
            let from:Vec<u16>=tmp.as_os_str().encode_wide().chain(Some(0)).collect();
            let to:Vec<u16>=path.as_os_str().encode_wide().chain(Some(0)).collect();
            if unsafe {MoveFileW(from.as_ptr(),to.as_ptr())}==0 {return Err(std::io::Error::last_os_error());}
        }
        #[cfg(not(windows))] fs::hard_link(&tmp,path)?;
        Ok(()) })();
    if created {let _=fs::remove_file(&tmp);}result.map_err(|e|e.to_string())
}
#[tauri::command]
pub async fn diagnostics_save_bundle(app: AppHandle, path: PathBuf, summary: Value, include_paths: bool) -> Result<String,String> {
    if !path.is_absolute() || path.extension().and_then(|x|x.to_str()).map(|x|x.eq_ignore_ascii_case("zip"))!=Some(true) {return Err("Choose an absolute ZIP destination.".into())}
    let summary_bytes=serde_json::to_vec_pretty(&summary).map_err(|e|e.to_string())?;
    if summary_bytes.len()>2*1024*1024 {return Err("Diagnostic summary is too large".into())}
    let d=app.state::<Diagnostics>(); let dir=d.directory.clone(); let mut settings=serde_json::to_value(d.config.lock().unwrap().clone()).unwrap();
    let previous=d.previous_session.clone(); if !include_paths {settings["directory"]=Value::String("[omitted]".into());}
    let result_path=path.clone();
    tauri::async_runtime::spawn_blocking(move || {
        reject_link_directory(&dir)?;
        let mut entries=vec![("summary.json".into(),summary_bytes),("settings.json".into(),serde_json::to_vec_pretty(&settings).unwrap()),
            ("previous-session.json".into(),serde_json::to_vec_pretty(&previous).unwrap()),
            ("README.txt".into(),b"SpektraLab Windows diagnostics. Saved locally at the user's request; nothing uploaded. Logs: newest five owned files, last 4 MiB each. With names disabled, whole records containing paths/image names are omitted. No image pixels are included.\n".to_vec())];
        for (i,(p,md)) in log_files(&dir).into_iter().take(5).enumerate() {
            let mut f=File::open(&p).map_err(|e|e.to_string())?; let limit=4*1024*1024u64;
            if md.len()>limit {f.seek(SeekFrom::End(-(limit as i64))).map_err(|e|e.to_string())?;}
            let mut bytes=Vec::new(); f.take(limit).read_to_end(&mut bytes).map_err(|e|e.to_string())?;
            let text=String::from_utf8_lossy(&bytes); let body=if include_paths {text.into_owned()} else {redact_logs(&text)};
            entries.push((format!("logs/session-{}.log",i+1),body.into_bytes()));
        }
        create_whole(&path,&zip(&entries))?; Ok::<_,String>(result_path.display().to_string())
    }).await.map_err(|e|e.to_string())?
}
pub fn write_job_log(result: &Value, params: &Value, elapsed_ms: u128) -> Result<(),String> {
    let path=PathBuf::from(result["path"].as_str().ok_or("Export did not return a path")?);
    if !path.is_absolute() || regular(&path).is_none() {return Err("Export job log needs a completed output file".into())}
    let name=path.file_name().unwrap().to_string_lossy();
    let log=path.with_file_name(format!("{name}.job-{}.json",stamp()));
    let bytes=serde_json::to_vec_pretty(&json!({"completed_ms":stamp(),"elapsed_ms":elapsed_ms,"request":params,"result":result})).map_err(|e|e.to_string())?;
    if bytes.len()>2*1024*1024{return Err("Export job log is too large".into())}
    create_whole(&log,&bytes)
}

#[cfg(test)] mod tests {
    use super::*;
    fn dir()->PathBuf { static N:std::sync::atomic::AtomicU64=std::sync::atomic::AtomicU64::new(0); let n=N.fetch_add(1,std::sync::atomic::Ordering::Relaxed);
        let d=std::env::temp_dir().join(format!("spk-diag-{}-{}-{n}",std::process::id(),stamp()));fs::create_dir_all(&d).unwrap();d }
    #[test] fn cleanup_preserves_foreign_files_and_current_session() {
        let d=dir(); for n in ["spektralab-1000-1.log","spektralab-1001-1.log","photo.nef","other.log","spektralab-not-owned.log"] {fs::write(d.join(n),b"test").unwrap();}
        assert_eq!(clean(&d,&Config::default(),"spektralab-1001-1.log",true).unwrap(),1);
        for n in ["spektralab-1001-1.log","photo.nef","other.log","spektralab-not-owned.log"] {assert!(d.join(n).exists());}fs::remove_dir_all(d).unwrap();
    }
    #[test] fn zip_crc_and_no_clobber() {
        assert_eq!(crc32(b"123456789"),0xcbf43926);
        let z=zip(&[("hello.txt".into(),b"hello world".to_vec()),("中文.json".into(),b"{}".to_vec())]);
        assert_eq!(&z[0..4],b"PK\x03\x04");assert_eq!(&z[z.len()-22..z.len()-18],b"PK\x05\x06");
        let d=dir();let p=d.join("test.zip");create_whole(&p,&z).unwrap();assert!(create_whole(&p,b"bad").is_err());assert_eq!(fs::read(&p).unwrap(),z);
        if let Some(target)=std::env::var_os("SPEKTRALAB_DIAGNOSTIC_TEST_ZIP") {fs::write(target,&z).unwrap();}fs::remove_dir_all(d).unwrap();
    }
    #[test] fn disabled_names_drop_whole_path_records() {
        let redacted=redact_logs("GPU ready\nopening D:/照片/foo.NEF\nfailed: secret name.IIQ\npath=\"/home/me/photo.jpg\"\nrender 250 ms");
        assert!(!redacted.contains("照片")&&!redacted.contains("secret")&&!redacted.contains("home"));assert!(redacted.contains("render 250 ms"));
    }
    #[test] fn invalid_settings_rejected() {let mut c=Config::default();assert!(c.validate().is_ok());c.files=0;assert!(c.validate().is_err());}
    #[test] fn old_rotations_are_evicted_but_active_file_survives() {
        let d=dir();let current="spektralab-1001-1.log";
        for n in [current,"spektralab-1001-1_2026-10-18_01-00-00.log","spektralab-1000-1.log"]{fs::write(d.join(n),b"log").unwrap();}
        let c=Config{files:1,..Config::default()};assert_eq!(clean(&d,&c,current,false).unwrap(),2);assert!(d.join(current).exists());fs::remove_dir_all(d).unwrap();
    }
    #[test] fn export_job_log_requires_completed_file_and_preserves_pixels() {
        let d=dir();let p=d.join("output.tiff");let result=json!({"path":p,"width":2,"height":1});
        assert!(write_job_log(&result,&json!({}),42).is_err());fs::write(&p,b"pixels").unwrap();
        write_job_log(&result,&json!({"source_path":"input.NEF","quality":92}),42).unwrap();
        let logs:Vec<_>=fs::read_dir(&d).unwrap().flatten().filter(|e|e.file_name().to_string_lossy().contains(".job-")).collect();
        assert_eq!(logs.len(),1);let job:Value=serde_json::from_slice(&fs::read(logs[0].path()).unwrap()).unwrap();
        assert_eq!(job["elapsed_ms"],42);assert_eq!(job["request"]["quality"],92);assert_eq!(fs::read(&p).unwrap(),b"pixels");fs::remove_dir_all(d).unwrap();
    }
}
