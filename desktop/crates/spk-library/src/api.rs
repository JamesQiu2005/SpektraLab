//! The calls the Library pages need, typed (the Mac's `LibraryAPI.swift`).
//! spklib's `API-SPEC.md` is the authority for every field; each reply type
//! keeps the fields it does not name in `extra`, so a newer helper's additions
//! are carried through to the webview rather than dropped.
//!
//! Paths given to these calls go through [`paths::to_helper`] (the helper's
//! generic form; a `\\?\` prefix stripped). Paths in replies are the helper's
//! form; [`paths::to_native`] spells them with backslashes on Windows.

use crate::error::{ErrorCode, LibraryError};
use crate::host::LibraryHost;
use crate::paths;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::path::Path;

type Extra = Map<String, Value>;

fn decode<T: DeserializeOwned>(method: &str, v: Value) -> Result<T, LibraryError> {
    serde_json::from_value(v)
        .map_err(|e| LibraryError::new(ErrorCode::Internal, format!("{method}: the reply does not decode: {e}")))
}

fn p(path: &Path) -> Value {
    Value::String(paths::path_to_helper(path))
}

/// Add `key: value` to an object when `value` is `Some`.
fn put<T: Serialize>(o: &mut Value, key: &str, value: Option<T>) {
    if let Some(v) = value {
        o[key] = serde_json::to_value(v).unwrap_or(Value::Null);
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SdkVersion {
    pub version: String,
    pub abi: i64,
    pub schema: i64,
    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaptureOneProbe {
    #[serde(default)]
    pub supported: bool,
    #[serde(default)]
    pub reason: Option<String>,
    /// `catalog` or `session`.
    #[serde(default)]
    pub document: Option<String>,
    #[serde(default)]
    pub document_uuid: Option<String>,
    /// e.g. `16.8.6.25 Pro Mac`.
    #[serde(default)]
    pub format: Option<String>,
    #[serde(default)]
    pub counts: Option<Value>,
    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibraryInfo {
    pub uuid: String,
    /// `catalog` or `session`.
    pub kind: String,
    #[serde(default)]
    pub name: Option<String>,
    pub path: String,
    /// `{kind, path, document_uuid, format, synced_at, write_back: false}` for a Capture One mirror.
    #[serde(default)]
    pub origin: Option<Value>,
    #[serde(default)]
    pub copied_from: Option<Value>,
    #[serde(default)]
    pub counts: Option<Value>,
    #[serde(flatten)]
    pub extra: Extra,
}

/// A library opened, created, linked or copied: its handle and `info`; `sync`
/// (a link) or `report` (a copy) stay in `extra`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenedLibrary {
    /// The handle (`"L1"`) every library method takes. It dies with the helper.
    pub library: String,
    pub info: LibraryInfo,
    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Collection {
    pub uuid: String,
    #[serde(default)]
    pub parent: Option<String>,
    /// `root`, `all_images`, `recent_imports`, `recent_captures`, `trash`,
    /// `in_library`, `project`, `group`, `album`, `smart_album`, `folder`, ...
    pub kind: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub position: Option<Value>,
    /// `capture_one` or `local`.
    #[serde(default)]
    pub origin: Option<String>,
    #[serde(default)]
    pub editable: bool,
    #[serde(default)]
    pub image_count: Option<i64>,
    #[serde(default)]
    pub created_at: Option<String>,
    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VariantRow {
    pub uuid: String,
    #[serde(default)]
    pub position: Option<i64>,
    #[serde(default)]
    pub rating: Option<i64>,
    #[serde(default)]
    pub color_tag: Option<i64>,
    #[serde(default)]
    pub edit_revision: Option<i64>,
    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImageRow {
    pub uuid: String,
    pub path: String,
    #[serde(default)]
    pub file_name: Option<String>,
    /// `raw`, `raster`, `movie`, `pair`, `other`.
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub rating: Option<i64>,
    #[serde(default)]
    pub color_tag: Option<i64>,
    #[serde(default)]
    pub trashed: bool,
    /// The camera's wall clock, no zone: `2024-01-08T23:39:04`.
    #[serde(default)]
    pub captured_local: Option<String>,
    #[serde(default)]
    pub variants: Vec<VariantRow>,
    /// Present when the query asked `check_files`.
    #[serde(default)]
    pub exists: Option<bool>,
    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImagePage {
    pub total: i64,
    #[serde(default)]
    pub offset: i64,
    pub images: Vec<ImageRow>,
}

/// `images.facets`: `total`, and the facets (`rating`, `color_tag`, `kind`,
/// `captured`, `camera`, `lens`, `keyword`, `edited`, `undescribed`) as sent.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Facets {
    pub total: i64,
    #[serde(flatten)]
    pub facets: Extra,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WatchedFolder {
    pub folder: String,
    pub path: String,
    #[serde(default)]
    pub recursive: bool,
    #[serde(default)]
    pub online: bool,
    #[serde(default)]
    pub image_count: Option<i64>,
    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Location {
    pub uuid: String,
    pub path: String,
    #[serde(default)]
    pub online: bool,
    #[serde(default)]
    pub image_count: Option<i64>,
    #[serde(flatten)]
    pub extra: Extra,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Edit {
    /// 0: never edited in this library.
    pub revision: i64,
    #[serde(default)]
    pub edit: Option<Value>,
    #[serde(flatten)]
    pub extra: Extra,
}

/// The `images.list` / `images.facets` scope and page. `filter` is the SDK's
/// filter object (`min_rating`, `ratings`, `color_tags`, `kinds`, `text`,
/// `captured_from`, `captured_to`, `camera_models`, `lenses`, `keywords`,
/// `has_edit`, `described`), passed through as given.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ImageQuery {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collection: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recursive: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub filter: Option<Map<String, Value>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub images: Option<Vec<String>>,
    /// `captured`, `imported`, `name`, `rating`, `added`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub descending: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub offset: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub check_files: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub full: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub include_trashed: Option<bool>,
}

impl ImageQuery {
    fn params(&self, library: &str) -> Value {
        let mut v = serde_json::to_value(self).unwrap_or_else(|_| json!({}));
        v["library"] = Value::String(library.to_string());
        v
    }
    /// The facets take the scope only.
    fn scope(&self, library: &str) -> Value {
        let mut v = json!({"library": library});
        put(&mut v, "collection", self.collection.clone());
        put(&mut v, "recursive", self.recursive);
        put(&mut v, "filter", self.filter.clone());
        put(&mut v, "include_trashed", self.include_trashed);
        v
    }
}

/// One `images.add` item: a file, and what the app read of its header
/// (`captured_local`, `width`, `height`, `camera_make`, ... -- spklib's
/// `images.add` metadata keys).
#[derive(Debug, Clone)]
pub struct AddItem<'a> {
    pub path: &'a Path,
    pub metadata: Option<Value>,
}

impl LibraryHost {
    fn typed<T: DeserializeOwned>(&self, method: &str, params: Value) -> Result<T, LibraryError> {
        decode(method, self.call(method, params)?)
    }

    // --- the helper ---------------------------------------------------------------------------

    pub fn sdk_version(&self) -> Result<SdkVersion, LibraryError> {
        self.typed("sdk.version", json!({}))
    }

    pub fn ping(&self) -> Result<(), LibraryError> {
        self.call("host.ping", json!({})).map(|_| ())
    }

    // --- sources: Capture One catalogs and sessions, SpektraLab libraries ----------------------

    /// A `.cocatalog`, its `.cocatalogdb`, a session folder or `.cosessiondb`: the verdict, read
    /// through a snapshot. Nothing of Capture One's is written.
    pub fn probe_capture_one(&self, path: &Path) -> Result<CaptureOneProbe, LibraryError> {
        self.typed("capture_one.probe", json!({"path": p(path)}))
    }

    /// Open a Capture One catalog as a mirror (`<store>/Linked/<document UUID>.spkcatalog`).
    /// A Capture One session is `unsupported` here (probe only).
    pub fn link_capture_one(&self, source: &Path) -> Result<OpenedLibrary, LibraryError> {
        self.typed("capture_one.link", json!({"source": p(source)}))
    }

    /// Copy a Capture One catalog into a new, independent SpektraLab catalog at `to`.
    pub fn copy_capture_one(&self, source: &Path, to: &Path, name: Option<&str>, mirror: Option<&str>)
        -> Result<OpenedLibrary, LibraryError> {
        let mut v = json!({"source": p(source), "path": p(to)});
        put(&mut v, "name", name);
        put(&mut v, "mirror", mirror);
        self.typed("capture_one.copy", v)
    }

    /// Bring a copy up to date with its Capture One catalog; SpektraLab's changes win.
    pub fn update_copy(&self, library: &str, source: Option<&Path>, dry_run: bool) -> Result<Value, LibraryError> {
        let mut v = json!({"library": library});
        put(&mut v, "source", source.map(p));
        if dry_run {
            v["dry_run"] = Value::Bool(true);
        }
        self.call("capture_one.update", v)
    }

    /// `kind`: `catalog` (a `.spkcatalog` is added to the name) or `session`.
    pub fn create_library(&self, path: &Path, kind: &str, name: Option<&str>) -> Result<OpenedLibrary, LibraryError> {
        let mut v = json!({"path": p(path), "kind": kind});
        put(&mut v, "name", name);
        self.typed("library.create", v)
    }

    pub fn open_library(&self, path: &Path) -> Result<OpenedLibrary, LibraryError> {
        self.typed("library.open", json!({"path": p(path)}))
    }

    pub fn close_library(&self, library: &str) -> Result<(), LibraryError> {
        self.call("library.close", json!({"library": library})).map(|_| ())
    }

    pub fn library_info(&self, library: &str) -> Result<LibraryInfo, LibraryError> {
        self.typed("library.info", json!({"library": library}))
    }

    /// A mirror re-read from its Capture One catalog; `{skipped: true}` when it has not changed.
    pub fn sync_library(&self, library: &str, force: bool) -> Result<Value, LibraryError> {
        self.call("library.sync", json!({"library": library, "force": force}))
    }

    // --- the browser ----------------------------------------------------------------------------

    pub fn collections(&self, library: &str) -> Result<Vec<Collection>, LibraryError> {
        let v = self.call("collections.list", json!({"library": library}))?;
        decode("collections.list", v.get("collections").cloned().unwrap_or(Value::Array(vec![])))
    }

    pub fn images(&self, library: &str, query: &ImageQuery) -> Result<ImagePage, LibraryError> {
        self.typed("images.list", query.params(library))
    }

    pub fn image(&self, library: &str, image: &str) -> Result<Value, LibraryError> {
        self.call("image.get", json!({"library": library, "image": image}))
    }

    pub fn facets(&self, library: &str, query: &ImageQuery) -> Result<Facets, LibraryError> {
        self.typed("images.facets", query.scope(library))
    }

    /// For each path: `{path, found, match {image, variant, origin_state}}`.
    pub fn lookup(&self, library: &str, paths_in: &[&Path]) -> Result<Vec<Value>, LibraryError> {
        let list: Vec<Value> = paths_in.iter().map(|x| p(x)).collect();
        let v = self.call("images.lookup", json!({"library": library, "paths": list}))?;
        decode("images.lookup", v.get("results").cloned().unwrap_or(Value::Array(vec![])))
    }

    /// What the app read of each file's header, for rows a folder sync added (`items[] {image, metadata}`).
    pub fn describe(&self, library: &str, items: Vec<Value>) -> Result<Value, LibraryError> {
        self.call("images.describe", json!({"library": library, "items": items}))
    }

    /// `copy`: into the library (a catalog's `Originals/yyyy/mm/dd`, a session's `Capture/`); otherwise referenced.
    pub fn add_images(&self, library: &str, items: &[AddItem<'_>], copy: bool, collection: Option<&str>)
        -> Result<Value, LibraryError> {
        let list: Vec<Value> = items
            .iter()
            .map(|i| match &i.metadata {
                Some(m) => json!({"path": p(i.path), "metadata": m}),
                None => p(i.path),
            })
            .collect();
        let mut v = json!({"library": library, "items": list, "mode": if copy { "copy" } else { "reference" }});
        put(&mut v, "collection", collection);
        self.call("images.add", v)
    }

    /// `rating` 0-5 and `color_tag` 0-7: `None` leaves it, `Some(None)` hands it back to Capture One.
    pub fn set_meta(&self, library: &str, variants: &[&str], rating: Option<Option<i64>>, color_tag: Option<Option<i64>>)
        -> Result<Value, LibraryError> {
        let mut v = json!({"library": library, "variants": variants});
        if let Some(r) = rating {
            v["rating"] = json!(r);
        }
        if let Some(c) = color_tag {
            v["color_tag"] = json!(c);
        }
        self.call("meta.set", v)
    }

    /// A flag only; no file moves.
    pub fn trash_images(&self, library: &str, images: &[&str], trashed: Option<bool>) -> Result<Value, LibraryError> {
        self.call("images.trash", json!({"library": library, "images": images, "trashed": trashed}))
    }

    // --- folders --------------------------------------------------------------------------------

    pub fn locations(&self, library: &str) -> Result<Vec<Location>, LibraryError> {
        let v = self.call("locations.list", json!({"library": library}))?;
        decode("locations.list", v.get("locations").cloned().unwrap_or(Value::Array(vec![])))
    }

    /// "Locate folder": `to` `None` undoes a relink.
    pub fn relink(&self, library: &str, location: &str, to: Option<&Path>) -> Result<Value, LibraryError> {
        self.call("location.relink", json!({"library": library, "location": location, "path": to.map(p)}))
    }

    pub fn add_folder(&self, library: &str, folder: &Path, recursive: bool, skip: &[&str]) -> Result<Value, LibraryError> {
        self.call("folders.add", json!({"library": library, "path": p(folder), "recursive": recursive, "skip": skip}))
    }

    pub fn watched_folders(&self, library: &str) -> Result<Vec<WatchedFolder>, LibraryError> {
        let v = self.call("folders.list", json!({"library": library}))?;
        decode("folders.list", v.get("folders").cloned().unwrap_or(Value::Array(vec![])))
    }

    /// One watched folder, or (`None`) every one and a session's own.
    pub fn sync_folders(&self, library: &str, folder: Option<&str>) -> Result<Value, LibraryError> {
        let mut v = json!({"library": library});
        put(&mut v, "folder", folder);
        self.call("folders.sync", v)
    }

    pub fn remove_folder(&self, library: &str, folder: &str) -> Result<Value, LibraryError> {
        self.call("folders.remove", json!({"library": library, "folder": folder}))
    }

    // --- albums -------------------------------------------------------------------------------

    /// `kind`: `album`, `group`, `project` or `smart_album` (with `criteria`, an `images.list` filter).
    pub fn create_collection(&self, library: &str, kind: &str, name: &str, parent: Option<&str>, criteria: Option<Value>)
        -> Result<String, LibraryError> {
        let mut v = json!({"library": library, "kind": kind, "name": name});
        put(&mut v, "parent", parent);
        put(&mut v, "criteria", criteria);
        let r = self.call("collection.create", v)?;
        r.get("collection")
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| LibraryError::new(ErrorCode::Internal, "collection.create: no collection in the reply"))
    }

    pub fn add_to_collection(&self, library: &str, collection: &str, images: &[&str]) -> Result<Value, LibraryError> {
        self.call("collection.add", json!({"library": library, "collection": collection, "images": images}))
    }

    // --- edits ----------------------------------------------------------------------------------

    pub fn edit(&self, library: &str, variant: &str) -> Result<Edit, LibraryError> {
        self.typed("edit.get", json!({"library": library, "variant": variant}))
    }

    /// The new revision, or `conflict` with [`LibraryError::conflict_revision`]. Never retry with
    /// the helper's revision blindly: reload, then reapply or ask.
    pub fn put_edit(&self, library: &str, variant: &str, edit: &Value, base_revision: i64) -> Result<i64, LibraryError> {
        let r = self.call("edit.put", json!({"library": library, "variant": variant, "edit": edit, "base_revision": base_revision}))?;
        r.get("revision")
            .and_then(Value::as_i64)
            .ok_or_else(|| LibraryError::new(ErrorCode::Internal, "edit.put: no revision in the reply"))
    }

    pub fn new_variant(&self, library: &str, image: &str, from_variant: Option<&str>) -> Result<Value, LibraryError> {
        let mut v = json!({"library": library, "image": image});
        put(&mut v, "from_variant", from_variant);
        self.call("variant.create", v)
    }

    /// spklib 0.4.0: `{variant, image, deleted: true, files_moved: false}`. The variant's row, edit and
    /// keywords go; never a file, never the image. `last_variant` for the image's last present variant
    /// (move the image to the Trash instead), `read_only` for one of Capture One's. Positions are not
    /// renumbered: show a variant's ordinal in `variants[]`, key it by `uuid`.
    pub fn delete_variant(&self, library: &str, variant: &str) -> Result<Value, LibraryError> {
        self.call("variant.delete", json!({"library": library, "variant": variant}))
    }

    /// spklib 0.3.1: forget images whose file is gone (`refused[]` with `file_present` / `read_only`).
    /// Rows only, never a file.
    pub fn remove_images(&self, library: &str, images: &[&str]) -> Result<Value, LibraryError> {
        self.call("images.remove", json!({"library": library, "images": images}))
    }
}
