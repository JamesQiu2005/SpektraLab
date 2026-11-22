//! Paths between the app and the helper.
//!
//! The helper speaks UTF-8 strings. On Windows its own form is the *generic*
//! one -- '/' separated, upper-case drive letter, `C:/Users/me/Pictures`,
//! `//server/share/x` -- and it compares paths case-insensitively (spklib
//! `src/platform.hpp`, `docs/WINDOWS.md`). Win32 accepts '/' everywhere except
//! after a `\\?\` prefix, so the app may use the helper's form as it is.
//!
//! What the client has to do on the way in is what the helper cannot know:
//! a `\\?\` (verbatim) prefix, which `std::fs::canonicalize` and some file
//! dialogs produce on Windows, names the same file as the plain path, but as a
//! string it is a different root -- the same folder would be stored twice and
//! `images.lookup` would miss. [`to_helper`] strips it, turns '\' into '/',
//! upper-cases the drive letter, and drops doubled and trailing separators.
//! On the way out, [`to_native`] gives the backslash form for display.
//!
//! The functions are pure and take a [`PathStyle`], so the tests exercise both
//! path styles on every platform (T-B4).

use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PathStyle {
    Posix,
    Windows,
}

#[cfg(windows)]
pub const NATIVE: PathStyle = PathStyle::Windows;
#[cfg(not(windows))]
pub const NATIVE: PathStyle = PathStyle::Posix;

fn is_drive(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() >= 2 && b[0].is_ascii_alphabetic() && b[1] == b':'
}

/// The helper's form of a path. Posix: unchanged (a '\' is a file-name
/// character there). Windows: see the module comment.
pub fn to_helper(path: &str, style: PathStyle) -> String {
    if style == PathStyle::Posix {
        return path.to_string();
    }
    let mut s = path.replace('\\', "/");
    // Verbatim and device prefixes: //?/C:/x, //?/UNC/server/share/x, //./C:/x.
    for prefix in ["//?/", "//./"] {
        if let Some(rest) = s.strip_prefix(prefix) {
            if rest.get(..4).is_some_and(|root| root.eq_ignore_ascii_case("UNC/")) {
                s = format!("//{}", &rest[4..]);
            } else if is_drive(rest) {
                s = rest.to_string();
            }
            break;
        }
    }
    // The root keeps its own shape; the rest loses doubled separators.
    let (root, rest) = if let Some(unc) = s.strip_prefix("//") {
        ("//".to_string(), unc.to_string())
    } else if is_drive(&s) {
        let drive = s[..1].to_ascii_uppercase();
        if s[2..].starts_with('/') {
            (format!("{drive}:/"), s[3..].to_string())
        } else {
            (format!("{drive}:"), s[2..].to_string())
        }
    } else if let Some(r) = s.strip_prefix('/') {
        ("/".to_string(), r.to_string())
    } else {
        (String::new(), s.clone())
    };
    let parts: Vec<&str> = rest.split('/').filter(|p| !p.is_empty()).collect();
    let joined = parts.join("/");
    if joined.is_empty() {
        return if root == "//" { String::new() } else { root };
    }
    format!("{root}{joined}")
}

/// The native spelling of a path the helper returned. Windows: '\'
/// separators (`C:\Users\me`, `\\server\share`). Posix: unchanged.
pub fn to_native(path: &str, style: PathStyle) -> String {
    match style {
        PathStyle::Posix => path.to_string(),
        PathStyle::Windows => path.replace('/', "\\"),
    }
}

/// [`to_helper`] for a `Path`, in this platform's style.
pub fn path_to_helper(path: &Path) -> String {
    to_helper(&path.to_string_lossy(), NATIVE)
}

/// Whether a path is inside (or is) a Capture One catalog package or a Capture
/// One session database: a component ending in `.cocatalog`, `.cocatalogdb` or
/// `.cosessiondb`. The client refuses to send such a path to any call that
/// creates or writes at it (R-B5); reading one (probe, link, copy *from*) is
/// how a catalog is opened. Case-insensitive, either separator.
pub fn inside_capture_one(path: &str) -> bool {
    path.split(['/', '\\']).any(|part| {
        let p = part.to_ascii_lowercase();
        p.ends_with(".cocatalog") || p.ends_with(".cocatalogdb") || p.ends_with(".cosessiondb")
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    const W: PathStyle = PathStyle::Windows;
    const X: PathStyle = PathStyle::Posix;

    #[test]
    fn drive_letters() {
        assert_eq!(to_helper(r"C:\Users\me\Pictures", W), "C:/Users/me/Pictures");
        assert_eq!(to_helper(r"c:\users\me\", W), "C:/users/me");
        assert_eq!(to_helper("d:/Shoots//2024/", W), "D:/Shoots/2024");
        assert_eq!(to_helper(r"C:\", W), "C:/");
        assert_eq!(to_helper("c:", W), "C:");
        assert_eq!(to_helper(r"C:rel\x", W), "C:rel/x"); // drive-relative stays relative
        assert_eq!(to_helper(r"\Photos\x", W), "/Photos/x"); // root of the current drive
        assert_eq!(to_helper(r"rel\x", W), "rel/x");
    }

    #[test]
    fn unc_and_verbatim_prefixes() {
        assert_eq!(to_helper(r"\\NAS\photos\2024", W), "//NAS/photos/2024");
        assert_eq!(to_helper(r"\\NAS\photos\", W), "//NAS/photos");
        assert_eq!(to_helper(r"\\?\C:\Users\me\x.NEF", W), "C:/Users/me/x.NEF");
        assert_eq!(to_helper(r"\\?\c:\", W), "C:/");
        assert_eq!(to_helper(r"\\?\UNC\srv\share\x", W), "//srv/share/x");
        assert_eq!(to_helper(r"\\?\unc\srv\share", W), "//srv/share");
        assert_eq!(to_helper(r"\\.\C:\x", W), "C:/x");
        // A verbatim path that is neither a drive nor UNC (a volume GUID) is left as the helper's root form.
        assert_eq!(to_helper(r"\\?\Volume{1234}\x", W), "//?/Volume{1234}/x");
        assert_eq!(to_helper(r"\\?\照片", W), "//?/照片");
        // Non-ASCII survives untouched (the helper does NFC and case folding itself).
        assert_eq!(to_helper("C:\\Users\\张三\\Café", W), "C:/Users/张三/Café");
    }

    #[test]
    fn posix_is_untouched() {
        for p in ["/Volumes/NIKON Z 8   /DCIM", "/a//b/", r"/a\b", "rel"] {
            assert_eq!(to_helper(p, X), p);
            assert_eq!(to_native(p, X), p);
        }
    }

    #[test]
    fn native_spelling_and_round_trip() {
        assert_eq!(to_native("C:/Users/me/x.NEF", W), r"C:\Users\me\x.NEF");
        assert_eq!(to_native("//NAS/photos/x", W), r"\\NAS\photos\x");
        for p in [r"C:\Users\me\x.NEF", r"\\NAS\photos\x", r"D:\"] {
            assert_eq!(to_native(&to_helper(p, W), W), p);
        }
    }

    #[test]
    fn capture_one_packages_are_recognised() {
        assert!(inside_capture_one("/Users/me/Pictures/Main.cocatalog"));
        assert!(inside_capture_one("/Users/me/Pictures/Main.cocatalog/Originals/x"));
        assert!(inside_capture_one(r"C:\Users\me\Main.COCATALOG\Main.cocatalogdb"));
        assert!(inside_capture_one("D:/Shoot/Shoot.cosessiondb"));
        assert!(!inside_capture_one("/Users/me/Pictures/Main.spkcatalog"));
        assert!(!inside_capture_one("/Users/me/cocatalog-notes/x"));
    }
}
