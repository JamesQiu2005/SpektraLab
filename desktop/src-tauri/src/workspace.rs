//! One OS lease for all overlapping GUI operations. CLI tools take the same
//! lease for their whole transaction; a GUI batch retains it between frames.
use crate::{agent_files, files::SidecarStore};
use serde_json::{json,Value};
use sha2::{Digest,Sha256};
use std::{collections::HashMap, fs::File, path::{Path, PathBuf}, sync::{Arc, Mutex}};

#[derive(Default)]
struct Active { file: Option<File>, users: usize, batch: Option<u64>, serial: u64 }
pub struct Workspace { root: PathBuf, active: Mutex<Active>, versions: Mutex<HashMap<(PathBuf,String),String>> }
pub struct Guard(Arc<Workspace>);
impl Drop for Guard {
    fn drop(&mut self) { if let Ok(mut a)=self.0.active.lock(){ a.users-=1; if a.users==0&&a.batch.is_none(){a.file=None;} } }
}
impl Workspace {
    pub fn new(root: PathBuf) -> Arc<Self> { Arc::new(Self{root,active:Mutex::new(Active::default()),versions:Mutex::new(HashMap::new())}) }
    pub fn enter(self: &Arc<Self>) -> Result<Guard,String> {
        let mut a=self.active.lock().map_err(|e|e.to_string())?;
        if a.file.is_none(){a.file=Some(agent_files::acquire(&self.root)?);}
        a.users+=1; Ok(Guard(Arc::clone(self)))
    }
    pub fn begin(&self) -> Result<u64,String> {
        let mut a=self.active.lock().map_err(|e|e.to_string())?;
        if a.batch.is_some(){return Err("A workspace batch is already running".into())}
        if a.file.is_none(){a.file=Some(agent_files::acquire(&self.root)?);}
        a.serial+=1; let token=a.serial;a.batch=Some(token);Ok(token)
    }
    pub fn end(&self,token:u64) -> Result<(),String> {
        let mut a=self.active.lock().map_err(|e|e.to_string())?;
        if a.batch!=Some(token){return Err("Workspace batch token does not match".into())}
        a.batch=None;if a.users==0{a.file=None;}Ok(())
    }
    pub fn load(&self,store:&SidecarStore,image:&Path)->Result<Option<Value>,String>{
        let _versions=self.versions.lock().map_err(|e|e.to_string())?;
        let mut value=store.load(image);let revision=revision(&value);
        if let Some(v)=value.as_mut(){v["_spkRevision"]=json!({"key":store.path_for(image),"base":revision});}
        Ok(value)
    }
    pub fn save(&self,store:&SidecarStore,image:&Path,value:&Value)->Result<PathBuf,String>{
        let mut versions=self.versions.lock().map_err(|e|e.to_string())?;
        let key=store.path_for(image);let disk=revision(&store.load(image));
        // The token travels with the edit snapshot (Sidecar.raw). Loading a
        // newer version in another UI task must never rebase an older edit.
        if let Some(token)=value.get("_spkRevision"){
            let base=token["base"].as_str().ok_or("Invalid sidecar revision")?;
            if !token["key"].is_string()||!(base=="missing"||base.len()==64&&base.bytes().all(|b|b.is_ascii_hexdigit())){
                return Err("Invalid sidecar revision".into())
            }
        }
        let base=if value["_spkRevision"]["key"]==json!(key){value["_spkRevision"]["base"].as_str().unwrap_or("missing")}else{"missing"}.to_string();
        let chain=(key,base.clone());let expected=versions.get(&chain).unwrap_or(&base);
        if expected!=&disk{
            return Err("EXTERNAL_EDIT_CONFLICT: This photo was edited by another process. Your unsaved edits are preserved; reload the photo to use the saved external edits.".into())
        }
        let mut clean=value.clone();if let Some(o)=clean.as_object_mut(){o.remove("_spkRevision");}
        let path=store.save(image,&clean)?;versions.insert(chain,revision(&store.load(image)));Ok(path)
    }
}
fn revision(value:&Option<Value>)->String{
    value.as_ref().map(|v|{let mut clean=v.clone();if let Some(o)=clean.as_object_mut(){o.remove("_spkRevision");}
        format!("{:x}",Sha256::digest(serde_json::to_vec(&clean).unwrap()))}).unwrap_or_else(||"missing".into())
}

#[cfg(test)] mod tests {
    use super::*;use serde_json::json;
    #[test] fn overlapping_gui_and_batch_exclude_agents_and_release_on_drop(){
        let root=std::env::temp_dir().join(format!("spk-workspace-{}",std::process::id()));
        let w=Workspace::new(root.clone());let g=w.enter().unwrap();let h=w.enter().unwrap();
        assert!(agent_files::acquire(&root).is_err());drop(g);assert!(agent_files::acquire(&root).is_err());
        let token=w.begin().unwrap();drop(h);assert!(agent_files::acquire(&root).is_err());
        assert!(w.end(token+1).is_err());w.end(token).unwrap();let cli=agent_files::acquire(&root).unwrap();
        assert!(w.enter().is_err());assert!(w.begin().is_err());drop(cli);drop(w.enter().unwrap());
        let _=std::fs::remove_dir_all(root);
    }
    #[test] fn external_sidecar_edits_are_not_overwritten(){
        let root=std::env::temp_dir().join(format!("spk-conflict-{}",std::process::id()));std::fs::create_dir_all(&root).unwrap();
        let image=root.join("source.png");std::fs::write(&image,b"fixture").unwrap();
        let store=SidecarStore{dir:root.join("Sidecars")};let w=Workspace::new(root.clone());
        assert!(w.load(&store,&image).unwrap().is_none());let original=json!({"edit":1});w.save(&store,&image,&original).unwrap();
        w.save(&store,&image,&json!({"edit":11})).unwrap(); // same local snapshot chain
        let mut snapshot=w.load(&store,&image).unwrap().unwrap();
        store.save(&image,&json!({"edit":2})).unwrap();
        let mut fresh=w.load(&store,&image).unwrap().unwrap(); // background read cannot rebase the old edit
        snapshot["edit"]=json!(3);
        assert!(w.save(&store,&image,&snapshot).unwrap_err().starts_with("EXTERNAL_EDIT_CONFLICT"));
        assert_eq!(store.load(&image).unwrap()["edit"],2);
        fresh["edit"]=json!(4);w.save(&store,&image,&fresh).unwrap();
        fresh["edit"]=json!(5);w.save(&store,&image,&fresh).unwrap();
        let final_value=store.load(&image).unwrap();assert_eq!(final_value["edit"],5);assert!(final_value.get("_spkRevision").is_none());
        let _=std::fs::remove_dir_all(root);
    }
}
