//! Bounded in-process byte transfers across the WebView bridge. A full TIFF
//! frame must not become one several-hundred-MB WebResource request/response.
use std::collections::HashMap;
use std::time::{Duration, Instant};

pub const CHUNK_BYTES: usize = 8 * 1024 * 1024;
const TTL: Duration = Duration::from_secs(600);

struct Entry {
    data: Vec<u8>,
    expected: usize,
    cursor: usize,
    upload_metadata: Option<String>,
    touched: Instant,
}

pub struct Transfers {
    entries: HashMap<String, Entry>,
    next: u64,
    reserved: usize,
    max_bytes: usize,
    max_entries: usize,
}

impl Default for Transfers {
    fn default() -> Self { Self::new(1024 * 1024 * 1024, 4) }
}

impl Transfers {
    fn new(max_bytes: usize, max_entries: usize) -> Self {
        Self { entries: HashMap::new(), next: 0, reserved: 0, max_bytes, max_entries }
    }
    fn insert(&mut self, entry: Entry) -> Result<String, String> {
        let expired: Vec<_> = self.entries.iter().filter(|(_, e)| e.touched.elapsed() > TTL)
            .map(|(id, _)| id.clone()).collect();
        for id in expired { self.drop_id(&id); }
        if self.entries.len() >= self.max_entries || entry.expected > self.max_bytes.saturating_sub(self.reserved) {
            return Err("binary transfer memory limit reached; finish or cancel the current operation".into());
        }
        self.next += 1;
        let id = format!("b{}", self.next);
        self.reserved += entry.expected;
        self.entries.insert(id.clone(), entry);
        Ok(id)
    }
    pub fn download(&mut self, data: Vec<u8>) -> Result<String, String> {
        let expected = data.len();
        self.insert(Entry { data, expected, cursor: 0, upload_metadata: None, touched: Instant::now() })
    }
    pub fn read(&mut self, id: &str, offset: usize) -> Result<Vec<u8>, String> {
        let entry = self.entries.get_mut(id).ok_or("binary download is no longer available")?;
        if entry.upload_metadata.is_some() || offset != entry.cursor || offset >= entry.expected {
            return Err("invalid binary download offset or direction".into());
        }
        let end = (offset + CHUNK_BYTES).min(entry.expected);
        let chunk = entry.data[offset..end].to_vec();
        entry.cursor = end;
        entry.touched = Instant::now();
        if end == entry.expected { self.drop_id(id); }
        Ok(chunk)
    }
    pub fn upload(&mut self, metadata: String, expected: usize) -> Result<String, String> {
        self.insert(Entry { data: Vec::new(), expected, cursor: 0,
            upload_metadata: Some(metadata), touched: Instant::now() })
    }
    pub fn append(&mut self, id: &str, offset: usize, bytes: &[u8]) -> Result<(), String> {
        let entry = self.entries.get_mut(id).ok_or("binary upload is no longer available")?;
        if entry.upload_metadata.is_none() || offset != entry.data.len() || bytes.is_empty() ||
            bytes.len() > CHUNK_BYTES || bytes.len() > entry.expected.saturating_sub(offset) {
            return Err("invalid binary upload offset, length or direction".into());
        }
        if entry.data.capacity() == 0 {
            entry.data.try_reserve_exact(entry.expected).map_err(|_| "could not allocate binary upload")?;
        }
        entry.data.extend_from_slice(bytes);
        entry.touched = Instant::now();
        Ok(())
    }
    pub fn finish(&mut self, id: &str) -> Result<(String, Vec<u8>), String> {
        let entry = self.entries.get(id).ok_or("binary upload is no longer available")?;
        if entry.upload_metadata.is_none() || entry.data.len() != entry.expected {
            return Err("binary upload is incomplete or has the wrong direction".into());
        }
        let entry = self.entries.remove(id).unwrap();
        self.reserved -= entry.expected;
        Ok((entry.upload_metadata.unwrap(), entry.data))
    }
    pub fn drop_id(&mut self, id: &str) {
        if let Some(entry) = self.entries.remove(id) { self.reserved -= entry.expected; }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn upload_order_completion_and_cancellation() {
        let mut pool = Transfers::new(16, 1);
        let id = pool.upload("request".into(), 5).unwrap();
        assert!(pool.upload("another".into(), 1).is_err());
        assert!(pool.append(&id, 1, &[4]).is_err());
        pool.append(&id, 0, &[1, 2]).unwrap();
        assert!(pool.finish(&id).is_err());
        assert!(pool.append(&id, 2, &[3, 4, 5, 6]).is_err());
        pool.append(&id, 2, &[3, 4, 5]).unwrap();
        assert_eq!(pool.finish(&id).unwrap(), ("request".into(), vec![1, 2, 3, 4, 5]));
        assert_eq!(pool.reserved, 0);
        let id = pool.upload("cancel".into(), 16).unwrap();
        pool.drop_id(&id); pool.drop_id(&id);
        assert_eq!(pool.reserved, 0);
        let empty = pool.upload("empty".into(), 0).unwrap();
        assert!(pool.finish(&empty).unwrap().1.is_empty());
    }
    #[test]
    fn download_crosses_chunk_boundary_exactly_once_and_releases_memory() {
        let data: Vec<_> = (0..CHUNK_BYTES+3).map(|i| (i % 251) as u8).collect();
        let mut pool = Transfers::new(data.len(), 1);
        let id = pool.download(data.clone()).unwrap();
        assert!(pool.read(&id, 1).is_err());
        let first = pool.read(&id, 0).unwrap();
        assert_eq!(first.len(), CHUNK_BYTES);
        assert!(pool.read(&id, 0).is_err());
        let last = pool.read(&id, CHUNK_BYTES).unwrap();
        assert_eq!(last.len(), 3);
        assert_eq!([first, last].concat(), data);
        assert_eq!(pool.reserved, 0);
        assert!(pool.read(&id, CHUNK_BYTES+3).is_err());
    }
    #[test]
    fn byte_limit_and_expired_transfer_recovery() {
        let mut pool = Transfers::new(3, 1);
        assert!(pool.download(vec![0; 4]).is_err());
        let id = pool.upload("expired".into(), 3).unwrap();
        pool.entries.get_mut(&id).unwrap().touched = Instant::now()-TTL-Duration::from_secs(1);
        let new_id = pool.download(vec![7, 8, 9]).unwrap();
        assert_eq!(pool.read(&new_id, 0).unwrap(), vec![7, 8, 9]);
        assert_eq!(pool.reserved, 0);
    }
}
