//! Durable document storage.

use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;

pub type StoreError = Box<dyn std::error::Error + Send + Sync>;

/// Where documents live. The channel keeps no document in memory: it loads
/// from the store whenever it serves state and appends every change before
/// relaying or acknowledging it, so any process can serve any document.
#[async_trait]
pub trait DocumentStore: Send + Sync + 'static {
    /// The document's full state as one v1 update, or `None` for a new document.
    async fn load(&self, key: &str) -> Result<Option<Vec<u8>>, StoreError>;

    /// Record `update`, the exact CRDT delta a client sent. Return only once it
    /// is durable: the client is told the change is saved as soon as this
    /// returns. A lost acknowledgment makes the client send the same update
    /// again, so the store must tolerate duplicates. An error rejects the
    /// change: it is neither relayed nor acknowledged.
    async fn append(&self, key: &str, update: &[u8]) -> Result<(), StoreError>;
}

/// Updates held in process memory: for tests and demos, not durable.
#[derive(Default)]
pub struct MemoryStore {
    documents: Mutex<HashMap<String, Vec<Vec<u8>>>>,
}

impl MemoryStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// How many updates `key` has recorded.
    pub fn len(&self, key: &str) -> usize {
        self.documents.lock().unwrap().get(key).map_or(0, Vec::len)
    }
}

#[async_trait]
impl DocumentStore for MemoryStore {
    async fn load(&self, key: &str) -> Result<Option<Vec<u8>>, StoreError> {
        let updates = self.documents.lock().unwrap().get(key).cloned();
        match updates {
            None => Ok(None),
            // Merging keeps updates whose dependencies have not arrived, so a
            // causal gap survives the load and heals when its dependency does.
            Some(updates) => Ok(Some(yrs::merge_updates_v1(&updates)?)),
        }
    }

    async fn append(&self, key: &str, update: &[u8]) -> Result<(), StoreError> {
        self.documents
            .lock()
            .unwrap()
            .entry(key.to_string())
            .or_default()
            .push(update.to_vec());
        Ok(())
    }
}
