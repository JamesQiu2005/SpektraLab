//! Narrow file service for the bundled CLI. Shares sidecar identity/migration
//! with the GUI; it never accepts an arbitrary write destination.
use crate::files::{self, SidecarStore};
use serde_json::{json, Value};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Manager};

#[derive(Debug, Default, serde::Deserialize, serde::Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RenderPreferences {
    recalculate_effects_after_crop: bool,
    di_blue_compensation: bool,
}
fn rendering_preferences(root: &Path) -> Result<RenderPreferences, String> {
    let bytes = match fs::read(root.join("Agents/rendering.json")) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(RenderPreferences::default()),
        Err(e) => return Err(format!("Cannot read saved rendering preferences: {e}")),
    };
    serde_json::from_slice(&bytes).map_err(|e| format!("Invalid saved rendering preferences: {e}"))
}
#[tauri::command]
pub fn agent_rendering_set(app: AppHandle, preferences: RenderPreferences) -> Result<(), String> {
    let root = app.path().app_data_dir().map_err(|e| e.to_string())?;
    // Only app-wide booleans; no image/sidecar access and no workspace lease.
    files::write_atomic(&root.join("Agents/rendering.json"), &serde_json::to_vec(&preferences).map_err(|e| e.to_string())?)
}

pub fn data_dir() -> Result<PathBuf, String> {
    #[cfg(windows)] let root = std::env::var_os("APPDATA").map(PathBuf::from);
    #[cfg(not(windows))] let root = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")));
    root.map(|p| p.join("app.spektralab.desktop")).ok_or_else(|| "Application data directory is unavailable".into())
}
pub fn enabled(root: &Path) -> bool {
    fs::read(root.join("Agents/access.json")).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()).and_then(|v| v["enabled"].as_bool()).unwrap_or(false)
}
/// OS-owned lock: process exit releases it, including a killed CLI. No stale
/// PID guesses or deletion of another process's lease file.
pub fn acquire(root: &Path) -> Result<File, String> {
    fs::create_dir_all(root.join("Agents")).map_err(|e| e.to_string())?;
    let mut options = OpenOptions::new(); options.read(true).write(true).create(true).truncate(false);
    #[cfg(windows)] { use std::os::windows::fs::OpenOptionsExt; options.share_mode(0); }
    let file = options.open(root.join("Agents/workspace.lock")).map_err(|_| "An application batch or agent operation is running. Try again when it finishes.".to_string())?;
    #[cfg(unix)] {
        use std::os::fd::AsRawFd;
        extern "C" { fn flock(fd: i32, operation: i32) -> i32; }
        if unsafe { flock(file.as_raw_fd(), 2 | 4) } != 0 { return Err("An application batch or agent operation is running.".into()); }
    }
    Ok(file)
}
fn installed_path() -> Result<PathBuf, String> {
    let home = std::env::var_os(if cfg!(windows) {"USERPROFILE"} else {"HOME"}).ok_or("Home directory unavailable")?;
    Ok(PathBuf::from(home).join(".local/bin").join(if cfg!(windows) {"spektralab.cmd"} else {"spektralab"}))
}
fn runtime() -> Result<(PathBuf, PathBuf), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let root = exe.parent().ok_or("Application directory unavailable")?;
    let dir = root.join("agents");
    #[cfg(target_os="linux")] let dir = if dir.is_dir() { dir } else {
        let prefix=std::env::var_os("APPDIR").map(PathBuf::from).unwrap_or_else(||PathBuf::from("/"));
        ["spektralab","SpektraLab","app.spektralab.desktop"].iter().map(|name|prefix.join("usr/lib").join(name).join("agents"))
            .find(|p|p.is_dir()).unwrap_or(dir)
    };
    Ok((dir.join(if cfg!(windows) {"node.exe"} else {"node"}), dir.join("agent.mjs")))
}
pub fn status(root: &Path) -> Result<Value, String> {
    let (node, script) = runtime()?;
    let installed = installed_path()?;
    Ok(json!({"enabled":enabled(root),"runtime_available":node.is_file()&&script.is_file(),
        "executable":installed,"command":format!("\"{}\" \"{}\"",node.display(),script.display()),
        "mcp_config":{"mcpServers":{"spektralab":{"command":node,"args":[script,"mcp"]}}}}))
}
#[tauri::command]
pub fn agent_access_get(app: AppHandle) -> Result<Value, String> { status(&app.path().app_data_dir().map_err(|e|e.to_string())?) }
#[tauri::command]
pub fn agent_access_set(app: AppHandle, enabled: bool) -> Result<Value, String> {
    let root=app.path().app_data_dir().map_err(|e|e.to_string())?;
    files::write_atomic(&root.join("Agents/access.json"), &serde_json::to_vec(&json!({"enabled":enabled})).unwrap())?;
    status(&root)
}
const MARKER: &str = "SpektraLab managed CLI wrapper";
#[tauri::command]
pub fn agent_cli_install() -> Result<String,String> {
    let (node,script)=runtime()?; if !node.is_file()||!script.is_file(){return Err("This build does not include the agent runtime.".into())}
    let target=installed_path()?;
    if target.exists()&&!fs::read_to_string(&target).map_err(|e|e.to_string())?.contains(MARKER){return Err("The command path contains another program; it was left unchanged.".into())}
    let text=if cfg!(windows){format!("@echo off\r\nsetlocal DisableDelayedExpansion\r\nrem {MARKER}\r\n\"{}\" \"{}\" %*\r\n",node.display().to_string().replace('%',"%%"),script.display().to_string().replace('%',"%%"))}
        else {format!("#!/bin/sh\n# {MARKER}\nexec '{}' '{}' \"$@\"\n",node.display().to_string().replace('\'',"'\\''"),script.display().to_string().replace('\'',"'\\''"))};
    files::write_atomic(&target,text.as_bytes())?;
    #[cfg(unix)] {use std::os::unix::fs::PermissionsExt; fs::set_permissions(&target,fs::Permissions::from_mode(0o755)).map_err(|e|e.to_string())?;}
    Ok(target.display().to_string())
}
#[tauri::command]
pub fn agent_cli_uninstall() -> Result<(),String> {
    let p=installed_path()?;if !p.exists(){return Ok(())}
    if !fs::read_to_string(&p).map_err(|e|e.to_string())?.contains(MARKER){return Err("The command is not SpektraLab's; it was left unchanged.".into())}
    fs::remove_file(p).map_err(|e|e.to_string())
}
pub fn serve() -> i32 {
    let root=match data_dir(){Ok(p)=>p,Err(e)=>{eprintln!("{e}");return 1}};
    let store=SidecarStore{dir:root.join("Sidecars")}; let mut lease:Option<File>=None;
    for line in std::io::stdin().lock().lines() {
        let line=match line {Ok(s)=>s,Err(_)=>return 1};
        if line.len()>2*1024*1024 {return 2}
        let q:Value=match serde_json::from_str(&line){Ok(v)=>v,Err(_)=>{println!("{{\"ok\":false,\"error\":\"Invalid JSON\"}}");continue}};
        let result=(||->Result<Value,String>{
            let method=q["method"].as_str().ok_or("Missing method")?; let p=&q["params"];
            if method=="status" {let mut s=status(&root)?;s["appData"]=json!(root);return Ok(s)}
            if method=="end" {lease=None;return Ok(json!({}))}
            if !enabled(&root) {return Err("Command line and agent access is off. Enable Settings > Agents.".into())}
            if method=="begin" {if lease.is_some(){return Err("A workspace lease is already held".into())} lease=Some(acquire(&root)?);return Ok(json!({}))}
            if lease.is_none(){return Err("A workspace operation lease is required".into())}
            match method {
                "rendering" => serde_json::to_value(rendering_preferences(&root)?).map_err(|e|e.to_string()),
                "sidecar_load"|"sidecar_save" => {
                    let path=PathBuf::from(p["path"].as_str().ok_or("Missing image path")?);
                    if !path.is_absolute()||!path.is_file()||(!files::is_image(&path)&&!crate::pairs::is_pair(&path)){return Err("An existing absolute image path is required".into())}
                    if method=="sidecar_load" {Ok(store.load(&path).unwrap_or(Value::Null))}
                    else {let v=&p["value"];if !v.is_object(){return Err("Sidecar must be an object".into())}let dest=store.save(&path,v)?;
                        let journal=root.join("Agents/changed.json");
                        let prior=fs::read(&journal).ok().and_then(|b|serde_json::from_slice::<Value>(&b).ok()).unwrap_or(Value::Null);
                        let mut paths:Vec<Value>=prior["paths"].as_array().cloned().unwrap_or_default();
                        let current=json!(path);paths.retain(|v|v!=&current);paths.push(current);
                        let overflow=prior["all"].as_bool().unwrap_or(false)||paths.len()>64;
                        if paths.len()>64 {paths.drain(..paths.len()-64);}
                        files::write_atomic(&journal,&serde_json::to_vec(&json!({"paths":paths,"all":overflow,"revision":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos().to_string()})).unwrap())?;
                        Ok(json!(dest))}
                },
                "recipes" => Ok(fs::read(root.join("Export/recipes.json")).ok().and_then(|b|serde_json::from_slice::<Value>(&b).ok()).unwrap_or(Value::Null)),
                _=>Err("Unknown agent file operation".into())
            }
        })();
        let response=match result{Ok(v)=>json!({"id":q["id"],"ok":true,"result":v}),Err(e)=>json!({"id":q["id"],"ok":false,"error":e})};
        println!("{response}");let _=std::io::stdout().flush();
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rendering_defaults_only_when_absent_and_preserves_both_switches() {
        let root=std::env::temp_dir().join(format!("spk-agent-prefs-{}-{}",std::process::id(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        assert_eq!(rendering_preferences(&root).unwrap(),RenderPreferences::default());
        fs::create_dir_all(root.join("Agents")).unwrap();
        let file=root.join("Agents/rendering.json");
        fs::write(&file,br#"{"recalculateEffectsAfterCrop":true,"diBlueCompensation":true}"#).unwrap();
        assert_eq!(rendering_preferences(&root).unwrap(),RenderPreferences{recalculate_effects_after_crop:true,di_blue_compensation:true});
        for invalid in [br#"{"diBlueCompensation":false}"#.as_slice(),br#"{"recalculateEffectsAfterCrop":"yes","diBlueCompensation":false}"#.as_slice(),b"broken"] {
            fs::write(&file,invalid).unwrap();assert!(rendering_preferences(&root).is_err());
        }
        fs::remove_file(&file).unwrap();fs::create_dir(&file).unwrap();assert!(rendering_preferences(&root).is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
