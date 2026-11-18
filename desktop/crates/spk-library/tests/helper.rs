//! T-B3: the client against a real helper, built on the Mac from the spklib
//! clone (gate.sh builds it). macOS only, by design: these tests are never
//! built or run for Windows (the Windows check is `cargo check` of the library).
//!
//!   SPKLIB_HOST=<spklib clone>/build/spklib-host \
//!   SPKLIB_FIXTURES=<spklib clone>/tests/fixtures cargo test
//!
//! Both variables are required: unset or pointing at nothing is a failure,
//! never a skip. The Capture One catalog is a synthetic one built from
//! spklib's fixture schema (`capture_one_16_8_schema.sql`, Capture One 16.8's
//! real schema) with /usr/bin/sqlite3, the way spklib's own tests build theirs.
#![cfg(target_os = "macos")]

use serde_json::{json, Value};
use spk_library::{AddItem, ErrorCode, ImageQuery, Launch, LibraryHost};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant, SystemTime};

fn required(var: &str) -> PathBuf {
    let v = std::env::var(var).unwrap_or_else(|_| panic!("{var} is not set; gate.sh sets it (a missing fixture is a failure)"));
    let p = PathBuf::from(v);
    assert!(p.exists(), "{var}={} does not exist", p.display());
    p
}

fn helper() -> PathBuf {
    required("SPKLIB_HOST")
}

/// A folder of the test's own, removed when the test ends (declare it first,
/// so the host is dropped -- and its helper gone -- before the folder goes).
struct Scratch(PathBuf);

impl std::ops::Deref for Scratch {
    type Target = Path;
    fn deref(&self) -> &Path {
        &self.0
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn scratch(name: &str) -> Scratch {
    let d = std::env::temp_dir().join(format!("spk-library-tests-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    // The helper stores resolved paths; /var is /private/var on a Mac.
    Scratch(d.canonicalize().unwrap())
}

fn host_in(dir: &Path) -> LibraryHost {
    LibraryHost::new(Launch::new(helper(), dir.join("store")))
}

fn touch(p: &Path, bytes: &str) {
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(p, bytes).unwrap();
}

fn process_exists(pid: u32) -> bool {
    Command::new("/bin/ps").args(["-p", &pid.to_string()]).output().map(|o| o.status.success()).unwrap_or(false)
}

#[test]
fn starts_on_first_use_and_speaks_abi_1() {
    let dir = scratch("start");
    let host = host_in(&dir);
    assert!(!host.is_running(), "nothing starts before the first call");
    let v = host.sdk_version().unwrap();
    assert_eq!(v.abi, 1);
    assert!(v.version.starts_with("0.4.0"), "{}", v.version);
    let ready = host.version().unwrap();
    assert!(ready.contains("0.4.0"), "the ready line: {ready}");
    assert_eq!(host.launches(), 1);
    host.ping().unwrap();
    assert!(dir.join("store").is_dir(), "the store is made and passed as --store");
    host.shutdown();
}

#[test]
fn an_unknown_method_is_unknown_method_and_the_helper_keeps_going() {
    let dir = scratch("unknown");
    let host = host_in(&dir);
    let e = host.call("images.paint", json!({})).unwrap_err();
    assert_eq!(e.code, ErrorCode::UnknownMethod, "{e}");
    let e = host.call("library.info", json!({"library": "L99"})).unwrap_err();
    assert_eq!(e.code, ErrorCode::NotFound, "{e}");
    let e = host.call("sdk.version", json!([1, 2])).unwrap_err();
    assert_eq!(e.code, ErrorCode::InvalidParams, "params must be an object");
    host.ping().unwrap();
    assert_eq!(host.launches(), 1, "errors are replies, not crashes");
}

#[test]
fn a_missing_helper_is_unavailable() {
    let dir = scratch("missing");
    let host = LibraryHost::new(Launch::new(dir.join("no-such-helper"), dir.join("store")));
    assert_eq!(host.ping().unwrap_err().code, ErrorCode::Unavailable);
}

#[test]
fn a_call_past_its_timeout_fails_and_the_next_one_works() {
    let dir = scratch("timeout");
    let host = host_in(&dir);
    host.start().unwrap();
    let e = host.call_with_timeout("sdk.methods", json!({}), Duration::ZERO).unwrap_err();
    assert_eq!(e.code, ErrorCode::Timeout);
    // The late reply is dropped; the next call gets its own.
    assert_eq!(host.sdk_version().unwrap().abi, 1);
    assert_eq!(host.launches(), 1);
}

#[test]
fn a_killed_helper_is_replaced_by_the_next_call() {
    let dir = scratch("kill");
    let host = host_in(&dir);
    let opened = host.create_library(&dir.join("Kill"), "catalog", None).unwrap();
    let first = host.pid().unwrap();
    assert!(Command::new("/bin/kill").args(["-9", &first.to_string()]).status().unwrap().success());
    let until = Instant::now() + Duration::from_secs(10);
    while host.is_running() {
        assert!(Instant::now() < until, "the client did not notice the helper died");
        std::thread::sleep(Duration::from_millis(20));
    }
    // The next call starts a new helper; the old handle names nothing in it.
    let e = host.library_info(&opened.library).unwrap_err();
    assert_eq!(e.code, ErrorCode::NotFound, "{e}");
    assert_eq!(host.launches(), 2);
    let second = host.pid().unwrap();
    assert_ne!(first, second);
    assert!(!process_exists(first), "the killed helper was reaped");
    let again = host.open_library(Path::new(&opened.info.path)).unwrap();
    assert_eq!(again.info.uuid, opened.info.uuid, "reopened by path, same library");
    host.shutdown();
    assert!(!process_exists(second));
}

#[test]
fn shutdown_and_drop_leave_no_process() {
    let dir = scratch("shutdown");
    let host = host_in(&dir);
    host.ping().unwrap();
    let pid = host.pid().unwrap();
    assert!(process_exists(pid));
    host.shutdown();
    assert!(!host.is_running());
    assert!(!process_exists(pid), "spklib-host {pid} outlived shutdown");
    // The next call after a shutdown starts a new one; dropping the host ends it.
    host.ping().unwrap();
    let pid2 = host.pid().unwrap();
    drop(host);
    assert!(!process_exists(pid2), "spklib-host {pid2} outlived drop");
}

#[test]
fn a_spektralab_catalog_through_the_typed_calls() {
    let dir = scratch("catalog");
    let photos = dir.join("Photos");
    touch(&photos.join("A.NEF"), "nef-a");
    touch(&photos.join("B.NEF"), "nef-b");
    touch(&photos.join("C.JPG"), "jpg-c");
    let host = host_in(&dir);
    let opened = host.create_library(&dir.join("Mine"), "catalog", Some("Mine")).unwrap();
    let l = opened.library.as_str();
    assert_eq!(opened.info.kind, "catalog");
    assert!(opened.info.path.ends_with("Mine.spkcatalog"), "{}", opened.info.path);
    assert!(Path::new(&opened.info.path).join("Library.spkdb").is_file());

    let a = photos.join("A.NEF");
    let items = [
        AddItem { path: &a, metadata: Some(json!({"captured_local": "2024-01-08T23:39:04", "camera_model": "NIKON Z6_3"})) },
        AddItem { path: &photos.join("B.NEF"), metadata: None },
        AddItem { path: &photos.join("C.JPG"), metadata: None },
    ];
    let added = host.add_images(l, &items, false, None).unwrap();
    assert_eq!(added["added"], json!(3), "{added}");
    let recent = added["recent_import"].as_str().expect("an import makes a Recent Imports album").to_string();

    let cols = host.collections(l).unwrap();
    for kind in ["root", "all_images", "recent_imports", "trash"] {
        assert!(cols.iter().any(|c| c.kind == kind), "no {kind} in {cols:?}");
    }
    assert!(cols.iter().any(|c| c.uuid == recent));

    let page = host.images(l, &ImageQuery { sort: Some("name".into()), check_files: Some(true), ..Default::default() }).unwrap();
    assert_eq!(page.total, 3);
    let names: Vec<_> = page.images.iter().map(|i| i.file_name.clone().unwrap_or_default()).collect();
    assert_eq!(names, ["A.NEF", "B.NEF", "C.JPG"]);
    assert!(page.images.iter().all(|i| i.exists == Some(true) && i.variants.len() == 1));
    let img_a = page.images[0].clone();
    assert_eq!(img_a.kind.as_deref(), Some("raw"));
    assert_eq!(img_a.captured_local.as_deref(), Some("2024-01-08T23:39:04"));
    let var_a = img_a.variants[0].uuid.clone();

    // A page, and a filter.
    let p2 = host.images(l, &ImageQuery { sort: Some("name".into()), offset: Some(1), limit: Some(1), ..Default::default() }).unwrap();
    assert_eq!((p2.total, p2.images.len(), p2.images[0].file_name.as_deref()), (3, 1, Some("B.NEF")));
    let mut raw_only = serde_json::Map::new();
    raw_only.insert("kinds".into(), json!(["raw"]));
    let raws = host.images(l, &ImageQuery { filter: Some(raw_only.clone()), ..Default::default() }).unwrap();
    assert_eq!(raws.total, 2);

    // Facets over the same scope.
    let f = host.facets(l, &ImageQuery::default()).unwrap();
    assert_eq!(f.total, 3);
    assert!(f.facets.contains_key("kind") && f.facets.contains_key("rating"), "{:?}", f.facets.keys());

    // Ratings, an album, describe, lookup.
    host.set_meta(l, &[&var_a], Some(Some(4)), None).unwrap();
    let mut four = serde_json::Map::new();
    four.insert("min_rating".into(), json!(4));
    assert_eq!(host.images(l, &ImageQuery { filter: Some(four), ..Default::default() }).unwrap().total, 1);
    let album = host.create_collection(l, "album", "Picks", None, None).unwrap();
    host.add_to_collection(l, &album, &[&img_a.uuid]).unwrap();
    assert_eq!(host.images(l, &ImageQuery { collection: Some(album.clone()), ..Default::default() }).unwrap().total, 1);
    let d = host.describe(l, vec![json!({"image": page.images[1].uuid, "metadata": {"camera_model": "NIKON Z 8"}})]).unwrap();
    assert_eq!(d["updated"], json!(1), "{d}");
    let found = host.lookup(l, &[&a, &photos.join("nope.NEF")]).unwrap();
    assert_eq!(found[0]["found"], json!(true));
    assert_eq!(found[0]["match"]["image"], json!(img_a.uuid));
    assert_eq!(found[1]["found"], json!(false));

    // An edit, its revision, and a conflict carrying the current revision.
    assert_eq!(host.edit(l, &var_a).unwrap().revision, 0);
    let r1 = host.put_edit(l, &var_a, &json!({"film": "kodak_portra_400"}), 0).unwrap();
    assert!(r1 > 0);
    let e = host.put_edit(l, &var_a, &json!({"film": "fuji"}), 0).unwrap_err();
    assert_eq!(e.code, ErrorCode::Conflict);
    assert_eq!(e.conflict_revision(), Some(r1));
    let got = host.edit(l, &var_a).unwrap();
    assert_eq!((got.revision, got.edit), (r1, Some(json!({"film": "kodak_portra_400"}))));
    let v2 = host.new_variant(l, &img_a.uuid, Some(&var_a)).unwrap();
    assert_eq!(v2["edit_copied"], json!(true), "{v2}");

    // A watched folder: added, listed, a new file noticed.
    let shoot = dir.join("Shoot");
    touch(&shoot.join("x.ARW"), "arw-x");
    let wf = host.add_folder(l, &shoot, true, &[]).unwrap();
    let folder = wf["folder"].as_str().unwrap().to_string();
    let listed = host.watched_folders(l).unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!((listed[0].folder.as_str(), listed[0].online), (folder.as_str(), true));
    touch(&shoot.join("sub/y.ARW"), "arw-y");
    let s = host.sync_folders(l, Some(&folder)).unwrap();
    assert_eq!(s["added"], json!(1), "{s}");
    assert_eq!(host.images(l, &ImageQuery::default()).unwrap().total, 5);
    assert!(host.locations(l).unwrap().iter().any(|loc| loc.path == shoot.to_string_lossy() && loc.online));

    // Trash is a flag; close, and reopen by path.
    host.trash_images(l, &[&page.images[2].uuid], Some(true)).unwrap();
    assert_eq!(host.images(l, &ImageQuery::default()).unwrap().total, 4);
    host.close_library(l).unwrap();
    let again = host.open_library(Path::new(&opened.info.path)).unwrap();
    assert_eq!(again.info.uuid, opened.info.uuid);
    assert_eq!(host.library_info(&again.library).unwrap().name.as_deref(), Some("Mine"));
    assert!(photos.join("C.JPG").is_file(), "images.trash never moves a file");
    host.shutdown();
}

#[test]
fn variants_are_deleted_and_filtered_by_their_own_keys_0_4_0() {
    let dir = scratch("variants");
    touch(&dir.join("Shoot/a.NEF"), "nef-a");
    touch(&dir.join("Shoot/b.NEF"), "nef-b");
    let host = host_in(&dir);
    let opened = host.create_library(&dir.join("V"), "catalog", None).unwrap();
    let l = opened.library.as_str();
    let a = dir.join("Shoot/a.NEF");
    let b = dir.join("Shoot/b.NEF");
    host.add_images(l, &[AddItem { path: &a, metadata: None }, AddItem { path: &b, metadata: None }], false, None).unwrap();
    let page = host.images(l, &ImageQuery { sort: Some("name".into()), ..Default::default() }).unwrap();
    let img = page.images[0].clone();
    let first = img.variants[0].uuid.clone();
    let second = host.new_variant(l, &img.uuid, None).unwrap()["variant"].as_str().unwrap().to_string();

    // 0.4.0: a variant's own rating matches its image, not only the primary's.
    host.set_meta(l, &[&second], Some(Some(4)), Some(Some(5))).unwrap();
    let mut four = serde_json::Map::new();
    four.insert("min_rating".into(), json!(4));
    let hit = host.images(l, &ImageQuery { filter: Some(four.clone()), ..Default::default() }).unwrap();
    assert_eq!((hit.total, hit.images[0].uuid.as_str()), (1, img.uuid.as_str()));
    assert_eq!(hit.images[0].rating, Some(0), "the row's rating stays the primary's");
    let facets = host.facets(l, &ImageQuery::default()).unwrap();
    assert!(facets.facets["rating"].as_array().unwrap().iter().any(|r| r["value"] == json!(4)), "{:?}", facets.facets["rating"]);

    // variant.delete: the variant goes, the image and its file stay; positions are not renumbered.
    let d = host.delete_variant(l, &first).unwrap();
    assert_eq!((d["deleted"].clone(), d["files_moved"].clone(), d["image"].clone()), (json!(true), json!(false), json!(img.uuid)));
    assert!(a.is_file(), "variant.delete never touches a file");
    let after = host.images(l, &ImageQuery { sort: Some("name".into()), ..Default::default() }).unwrap();
    assert_eq!(after.total, 2);
    let row = after.images.iter().find(|i| i.uuid == img.uuid).unwrap();
    assert_eq!(row.variants.len(), 1);
    assert_eq!(row.variants[0].uuid, second);
    assert_eq!(row.variants[0].position, Some(2), "positions are not renumbered");
    assert_eq!(row.rating, Some(4), "the next variant became the primary");
    let e = host.delete_variant(l, &second).unwrap_err();
    assert_eq!(e.code, ErrorCode::LastVariant, "{e}");
    assert_eq!(host.delete_variant(l, "no-such-variant").unwrap_err().code, ErrorCode::NotFound);

    // images.remove forgets a row only when its file is gone.
    let r = host.remove_images(l, &[&row.uuid]).unwrap();
    assert_eq!(r["refused"][0]["code"], json!("file_present"), "{r}");
    fs::remove_file(&a).unwrap();
    let r = host.remove_images(l, &[&row.uuid]).unwrap();
    assert_eq!(r["removed"], json!(1), "{r}");
    assert_eq!(host.images(l, &ImageQuery::default()).unwrap().total, 1);
    host.shutdown();
}

// --- Capture One: read, never written ----------------------------------------------------------

struct FakeCatalog {
    package: PathBuf,
}

fn sql_quote(s: &str) -> String {
    s.replace('\'', "''")
}

/// The Capture One 16.8 schema from spklib's fixtures, and a catalog's worth
/// of rows (spklib tests/tests.cpp `FakeCatalog`, cut down).
fn fake_catalog(root: &Path) -> FakeCatalog {
    let package = root.join("Fake.cocatalog");
    let photos = root.join("Photos");
    fs::create_dir_all(package.join("Originals/2026/01/02/1")).unwrap();
    touch(&photos.join("A.NEF"), "nef-a");
    touch(&photos.join("B.NEF"), "nef-b");
    touch(&photos.join("Sub/D.ARW"), "arw-d");
    touch(&package.join("Originals/2026/01/02/1/E.tif"), "tif-e");
    let schema = fs::read_to_string(required("SPKLIB_FIXTURES").join("capture_one_16_8_schema.sql")).unwrap();
    let rel = sql_quote(photos.to_string_lossy().trim_start_matches('/'));
    let up = sql_quote(root.to_string_lossy().trim_start_matches('/'));
    let rows = format!(
        "INSERT INTO ZVERSIONINFO VALUES (32, 1, '16.8.6.25 Pro Mac', '9.0.0 Mac', 160800, '16.8.6.25 Pro Mac', 160800);
INSERT INTO ZDOCUMENTCONTENT (Z_ENT, Z_PK, ZDATECREATED, ZDOCUMENTTYPE, ZDOCUMENTUUID, ZROOTCOLLECTION) VALUES (34, 1, 1729735821, 1, '11111111-2222-3333-4444-555555555555', 1);
INSERT INTO ZPATHLOCATION (Z_ENT, Z_PK, ZMACROOT, ZRELATIVEPATH, ZISRELATIVE, ZVOLUME) VALUES
 (38, 3, '/', '{rel}', 0, '/'), (38, 4, '/', '{rel}/Sub', 0, '/'), (38, 5, NULL, 'Originals/2026/01/02/1', 1, NULL), (38, 6, '/', '{up}', 0, '/');
INSERT INTO ZIMAGE (Z_ENT, Z_PK, ZIMAGEUUID, ZIMAGEFILENAME, ZDISPLAYNAME, ZIMAGELOCATION, ZISINSIDECATALOG, ZISTRASHED, ZIMAGECLASSIFICATION, ZWIDTH, ZHEIGHT, ZEXP_DATE, ZIMPORTDATE, ZCAMERA_MAKE, ZCAMERA_MODEL, ZISO) VALUES
 (12, 1, 'IMG-A', 'A.NEF', 'A', 3, 0, 0, 17, 6048, 4032, 1704757144.25, 1729841315.9, 'NIKON CORPORATION', 'NIKON Z6_3', 250),
 (12, 2, 'IMG-B', 'B.NEF', 'B', 3, 0, 0, 17, 6048, 4032, 1704757148, 1729841315.9, 'NIKON CORPORATION', 'NIKON Z6_3', 1000),
 (12, 4, 'IMG-D', 'D.ARW', 'D', 4, 0, 0, 17, 9504, 6336, 1704757200, 1729841316, 'SONY', 'ILCE-7RM5', 100),
 (12, 5, 'IMG-E', 'E.tif', 'E', 5, 1, 0, 19, 100, 100, NULL, 1729841317, NULL, NULL, NULL);
INSERT INTO ZVARIANT (Z_ENT, Z_PK, ZINDEX, ZVARIANTUUID, ZIMAGE, ZCOMBINEDSETTINGS, ZISMODIFIED) VALUES
 (15, 1, 127, 'VAR-A1', 1, 101, 0), (15, 3, 127, 'VAR-B1', 2, 103, 0), (15, 5, 127, 'VAR-D1', 4, 105, 0), (15, 6, 127, 'VAR-E1', 5, 106, 0);
INSERT INTO ZVARIANTLAYER (Z_ENT, Z_PK, ZVARIANT, ZROTATION, ZFLIP) VALUES (20, 101, 1, 0, 0), (20, 103, 3, 0, 0), (20, 105, 5, 0, 0), (20, 106, 6, 0, 0);
INSERT INTO ZVARIANTMETADATA (Z_ENT, Z_PK, ZLAYER, ZBASIC_RATING, ZCOLOR_TAG_INDEX) VALUES (13, 101, 101, 0, 0), (13, 103, 103, 3, 2), (13, 105, 105, 1, 0), (13, 106, 106, 0, 0);
INSERT INTO ZCOLLECTION (Z_ENT, Z_PK, ZUUID, ZNAME, ZPARENT, ZCOLLECTIONINDEX, ZFOLDERLOCATION, ZALLIMAGESCOLLECTION, ZLASTIMPORTSCOLLECTION, ZLASTCAPTURESCOLLECTION, ZTRASHCOLLECTION) VALUES
 (7, 1, 'COL-ROOT', 'root', NULL, 0, NULL, 2, 3, 4, 5),
 (40, 2, 'COL-ALL', '全部图像', 1, 1, NULL, NULL, NULL, NULL, NULL),
 (8, 3, 'COL-RI', '最近导入', 1, 2, NULL, NULL, NULL, NULL, NULL),
 (8, 4, 'COL-RC', '最近拍摄', 1, 3, NULL, NULL, NULL, NULL, NULL),
 (11, 5, 'COL-TRASH', '回收箱', 1, 4, NULL, NULL, NULL, NULL, NULL),
 (2, 8, 'COL-PICKS', 'Picks', 1, 6, NULL, NULL, NULL, NULL, NULL);
INSERT INTO ZIMAGEINCOLLECTION (Z_ENT, Z_PK, ZCOLLECTION, ZIMAGE) VALUES (47, 4, 8, 2), (47, 5, 8, 4);
"
    );
    let db = package.join("Fake.cocatalogdb");
    let script = root.join("make-catalog.sql");
    fs::write(&script, format!("{schema}\n{rows}")).unwrap();
    let st = Command::new("/usr/bin/sqlite3")
        .arg(&db)
        .arg(format!(".read {}", script.display()))
        .status()
        .expect("/usr/bin/sqlite3");
    assert!(st.success(), "building the fake catalog failed");
    fs::remove_file(&script).unwrap();
    FakeCatalog { package }
}

/// Every entry under the package: kind, size, modification time, permissions
/// and the bytes themselves (the fixture is small: a byte census is stronger
/// than a hash of one).
fn census(root: &Path) -> BTreeMap<PathBuf, (bool, u64, Option<SystemTime>, u32, Vec<u8>)> {
    use std::os::unix::fs::PermissionsExt;
    let mut out = BTreeMap::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(p) = stack.pop() {
        let md = fs::symlink_metadata(&p).unwrap();
        let bytes = if md.is_file() { fs::read(&p).unwrap() } else { Vec::new() };
        out.insert(p.clone(), (md.is_dir(), md.len(), md.modified().ok(), md.permissions().mode(), bytes));
        if md.is_dir() {
            for e in fs::read_dir(&p).unwrap() {
                stack.push(e.unwrap().path());
            }
        }
    }
    out
}

#[test]
fn a_capture_one_catalog_is_read_and_never_written() {
    let dir = scratch("capture-one");
    let fc = fake_catalog(&dir);
    let before = census(&fc.package);
    assert!(before.len() >= 6, "the census sees the package: {}", before.len());
    {
        let host = host_in(&dir);
        let probe = host.probe_capture_one(&fc.package).unwrap();
        assert!(probe.supported, "{probe:?}");
        assert_eq!(probe.document_uuid.as_deref(), Some("11111111-2222-3333-4444-555555555555"));
        assert_eq!(probe.format.as_deref(), Some("16.8.6.25 Pro Mac"));
        assert_eq!(probe.counts.as_ref().unwrap()["images"], json!(4));

        let mirror = host.link_capture_one(&fc.package).unwrap();
        let m = mirror.library.as_str();
        assert!(mirror.info.path.starts_with(&*dir.join("store").to_string_lossy()), "{}", mirror.info.path);
        assert_eq!(mirror.info.origin.as_ref().unwrap()["write_back"], json!(false));
        let cols = host.collections(m).unwrap();
        let all = cols.iter().find(|c| c.kind == "all_images").expect("all_images");
        assert_eq!(all.origin.as_deref(), Some("capture_one"));
        assert!(!all.editable, "Capture One's rows are not editable");
        let page = host.images(m, &ImageQuery { sort: Some("name".into()), check_files: Some(true), ..Default::default() }).unwrap();
        assert_eq!(page.total, 4);
        assert!(page.images.iter().all(|i| i.exists == Some(true)), "{:?}", page.images.iter().map(|i| &i.path).collect::<Vec<_>>());
        let picks = cols.iter().find(|c| c.name.as_deref() == Some("Picks")).unwrap();
        assert_eq!(host.images(m, &ImageQuery { collection: Some(picks.uuid.clone()), ..Default::default() }).unwrap().total, 2);
        // Capture One's album is read-only; a SpektraLab rating is kept beside Capture One's.
        let e = host.add_to_collection(m, &picks.uuid, &[&page.images[0].uuid]).unwrap_err();
        assert_eq!(e.code, ErrorCode::ReadOnly);
        host.set_meta(m, &[&page.images[0].variants[0].uuid], Some(Some(5)), None).unwrap();
        let s = host.sync_library(m, true).unwrap();
        assert!(s.is_object(), "{s}");
        assert!(host.facets(m, &ImageQuery::default()).unwrap().total == 4);

        // A copy: a new SpektraLab catalog, updated from the catalog later.
        let copy = host.copy_capture_one(&fc.package, &dir.join("Copy"), None, Some(m)).unwrap();
        assert!(copy.info.path.ends_with("Copy.spkcatalog"));
        assert_eq!(host.images(&copy.library, &ImageQuery::default()).unwrap().total, 4);
        let u = host.update_copy(&copy.library, None, false).unwrap();
        assert!(u.is_object(), "{u}");

        // Nothing is ever created inside the package, by the helper or by asking.
        for e in [
            host.create_library(&fc.package.join("Inside"), "catalog", None).unwrap_err(),
            host.copy_capture_one(&fc.package, &fc.package.join("Copy2"), None, None).unwrap_err(),
            host.add_folder(m, &fc.package.join("Originals"), true, &[]).unwrap_err(),
        ] {
            assert_eq!(e.code, ErrorCode::InvalidParams, "{e}");
        }
        // The helper's own answer, without this client's guard in the way.
        let e = host.call("library.create", json!({"path": format!("{}/Sub/Inside", fc.package.display()), "kind": "session"}));
        assert!(e.is_err() || !fc.package.join("Sub/Inside").exists());
        host.shutdown();
    }
    let after = census(&fc.package);
    let changed: Vec<_> = before
        .iter()
        .filter(|(p, v)| after.get(*p) != Some(v))
        .map(|(p, _)| p.clone())
        .chain(after.keys().filter(|p| !before.contains_key(*p)).cloned())
        .collect();
    assert!(changed.is_empty(), "the Capture One package changed: {changed:?}");
    assert_eq!(before.len(), after.len());
}

#[test]
fn the_contract_types_carry_unknown_fields_through() {
    let dir = scratch("extra");
    let host = host_in(&dir);
    let v = host.sdk_version().unwrap();
    // `capture_one {write_back: false, previews: false}` is not a named field: it travels in extra.
    assert_eq!(v.extra["capture_one"]["write_back"], json!(false));
    let back: Value = serde_json::to_value(&v).unwrap();
    assert_eq!(back["capture_one"]["previews"], json!(false));
}
