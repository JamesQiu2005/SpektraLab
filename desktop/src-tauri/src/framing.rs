//! HOST-PROTOCOL.md §1 framing, both directions:
//! `u32 LE header_len · u32 LE payload_len · JSON header · payload`.
//!
//! The same layout is reused for the reply the UI receives from
//! `host_request`, so pixels never pass through JSON: the webview gets one
//! `ArrayBuffer` and decodes it with `src/shared/framing.ts`.

use serde_json::Value;
use tokio::io::{AsyncRead, AsyncReadExt};

pub const MAX_HEADER_BYTES: u32 = 64 * 1024 * 1024;

pub fn encode(header: &Value, payload: &[u8]) -> Vec<u8> {
    let json = serde_json::to_vec(header).expect("a serde_json::Value always serialises");
    let mut out = Vec::with_capacity(8 + json.len() + payload.len());
    out.extend_from_slice(&(json.len() as u32).to_le_bytes());
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(&json);
    out.extend_from_slice(payload);
    out
}

/// Split one complete frame held in memory (used for UI → core uploads).
pub fn decode_one(bytes: &[u8]) -> Result<(Value, &[u8]), String> {
    if bytes.len() < 8 {
        return Err("frame shorter than its length prefix".into());
    }
    let h = u32::from_le_bytes(bytes[0..4].try_into().unwrap()) as usize;
    let p = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize;
    if bytes.len() != 8 + h + p {
        return Err(format!("frame length mismatch: {} != 8 + {} + {}", bytes.len(), h, p));
    }
    let header: Value = serde_json::from_slice(&bytes[8..8 + h]).map_err(|e| e.to_string())?;
    Ok((header, &bytes[8 + h..]))
}

/// Read one frame from the host's stdout. `Ok(None)` is a clean EOF between
/// frames; EOF inside a frame is an error.
pub async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> std::io::Result<Option<(Value, Vec<u8>)>> {
    let mut head = [0u8; 8];
    let mut got = 0;
    while got < 8 {
        let n = r.read(&mut head[got..]).await?;
        if n == 0 {
            return if got == 0 {
                Ok(None)
            } else {
                Err(std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "EOF inside a frame header"))
            };
        }
        got += n;
    }
    let h = u32::from_le_bytes(head[0..4].try_into().unwrap());
    let p = u32::from_le_bytes(head[4..8].try_into().unwrap());
    if h > MAX_HEADER_BYTES {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, format!("header length {h} exceeds bound")));
    }
    let mut json = vec![0u8; h as usize];
    r.read_exact(&mut json).await?;
    let mut payload = vec![0u8; p as usize];
    r.read_exact(&mut payload).await?;
    let header: Value = serde_json::from_slice(&json)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, format!("malformed JSON header: {e}")))?;
    Ok(Some((header, payload)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn round_trip() {
        let a = encode(&json!({"id": 1, "ok": true, "result": {"x": "漢"}}), &[1, 2, 3]);
        let b = encode(&json!({"event": "log"}), &[]);
        let mut all = a.clone();
        all.extend_from_slice(&b);
        let mut r = &all[..];
        let (h1, p1) = read_frame(&mut r).await.unwrap().unwrap();
        assert_eq!(h1["result"]["x"], "漢");
        assert_eq!(p1, vec![1, 2, 3]);
        let (h2, p2) = read_frame(&mut r).await.unwrap().unwrap();
        assert_eq!(h2["event"], "log");
        assert!(p2.is_empty());
        assert!(read_frame(&mut r).await.unwrap().is_none());
        let (h, p) = decode_one(&a).unwrap();
        assert_eq!(h["id"], 1);
        assert_eq!(p, &[1, 2, 3]);
    }

    #[tokio::test]
    async fn truncated_frame_is_an_error() {
        let a = encode(&json!({"id": 1}), &[1, 2, 3]);
        let mut r = &a[..a.len() - 1];
        assert!(read_frame(&mut r).await.is_err());
    }
}
