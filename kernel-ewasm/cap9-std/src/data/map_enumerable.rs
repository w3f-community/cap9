extern crate pwasm_abi;
use pwasm_abi::types::*;
use cap9_core::Serialize;
use cap9_core::StorageValue;

/// Generic wasm error
#[derive(Debug)]
pub struct Error;

use crate::proc_table;
use crate::syscalls::*;
use crate::*;
use crate::data::*;

use core::marker::PhantomData;

/// Same as [`StorageMap`], but can be enumerated/iterated.
///
/// A [`StorageEnumerableMap`] is the same as a [`StorageMap`] except that it stores
/// additional data that allows it to be enumerable/iterateable. Both data
/// structures are made available as the enumerable variant is more expensive
/// due to the extra data it must store.
pub struct StorageEnumerableMap<K,V> {
    cap_index: u8,
    /// The start location of the map.
    location: H256,
    /// The key type of the map.
    key_type: PhantomData<K>,
    /// The data type of the map.
    data_type: PhantomData<V>,
    /// Possible the cached number of elements in the map.
    length: Option<U256>,
}

impl<K: Keyable, V: Storable> StorageEnumerableMap<K,V> {

    // The location is dictated by the capability. A more specific location will
    // simply require a more specific capability. This means the procedure needs
    // to access capability data.
    //
    // TODO: there is some risk that there is storage on this cap that is not
    // compatible. I don't know if there is a way to make this type-safe, as
    // there is no type information. Validating the current contents would be
    // prohibitively expensive.

    /// Derive a [`StorageEnumerableMap`] from the cap at the given index.
    pub fn from(cap_index: u8) -> Result<Self, DataStructureError> {
        // The size of the cap needs to be key_width+1 in bytes
        let address_bytes = K::key_width()+1;
        let address_bits = address_bytes*8;
        let address_size = U256::from(2).pow(U256::from(address_bits));
        // The address also need to be aligned.
        let this_proc_key = proc_table::get_current_proc_id();
        if let Some(proc_table::cap::Capability::StoreWrite(proc_table::cap::StoreWriteCap {location, size})) =
                proc_table::get_proc_cap(this_proc_key, proc_table::cap::CAP_STORE_WRITE, cap_index) {
                    // Check that the size of the cap is correct.
                    if U256::from(size) < address_size {
                        Err(DataStructureError::TooSmall)
                    } else if U256::from(location).trailing_zeros() < (address_bits as u32 + 1 + 1) {
                        // the trailing number of 0 bits should be equal to or greater than the address_bits
                        Err(DataStructureError::MisAligned)
                    } else {
                        Ok(StorageEnumerableMap {
                            cap_index,
                            location: location.into(),
                            key_type: PhantomData,
                            data_type: PhantomData,
                            length: None,
                        })
                    }
        } else {
            Err(DataStructureError::BadCap)
        }
    }

    /// Return the start/base location of the map.
    pub fn location(&self) -> H256 {
        self.location
    }

    /// Return the base storage key of a given map key.
    fn base_key(&self, key: &K) -> [u8; 32] {
        let mut base: [u8; 32] = [0; 32];
        // The key start 32 - width - 1, the -1 is for data and presence
        let key_start = 32 - K::key_width() as usize - 1;
        // First we copy in the relevant parts of the location.
        base[0..key_start].copy_from_slice(&self.location().as_bytes()[0..key_start]);
        // Then we copy in the key
        // TODO: overflow
        base[key_start..(key_start+K::key_width() as usize)].clone_from_slice(key.key_slice().as_slice());
        base
    }

    fn presence_key(&self, key: &K) -> H256 {
        // The presence_key is the storage key which indicates whether there is
        // a value associated with this key.
        let mut presence_key = self.base_key(&key);
        // The first bit of the data byte indicates presence
        presence_key[31] = presence_key[31] | 0b10000000;
        presence_key.into()
    }

    fn length_key(&self) -> H256 {
        // The presence_key is the storage key which indicates whether there is
        // a value associated with this key.
        let mut location = self.location.clone();
        let length_key = location.as_fixed_bytes_mut();
        let index = 31 - 1 - K::key_width();
        length_key[index as usize] = length_key[index as usize] | 0b00000001;
        length_key.into()
    }

    /// Return the number of elements in the map.
    pub fn length(&self) -> U256 {
        match self.length {
            // A cached value exists, use that.
            Some(l) => l,
            // No cached value exists, read from storage.
            None => {
                let length = U256::from(pwasm_ethereum::read(&self.length_key()));
                length
            }
        }
    }

    fn increment_length(&mut self) {
        self.length = Some(self.length().checked_add(1.into()).unwrap());
        // Store length value.
        write(self.cap_index, &self.length_key().to_fixed_bytes(), &self.length().into()).unwrap();
    }

    /// Return true if the given key is associated with a value in the map.
    pub fn present(&self, key: &K) -> bool {
        // If the value at the presence key is non-zero, then a value is
        // present.
        let present = pwasm_ethereum::read(&self.presence_key(key));
        present != [0; 32]
    }

    fn set_present(&self, key: &K) {
        // If the value at the presence key is non-zero, then a value is
        // present.
        write(self.cap_index, &self.presence_key(key).as_fixed_bytes(), H256::repeat_byte(0xff).as_fixed_bytes()).unwrap();
    }

    /// Get the value associated with a given key, if it exists.
    pub fn get(&self, key: K) -> Option<V> {
        let base = self.base_key(&key);
        if self.present(&key) {
            V::read(base.into())
        } else {
            None
        }
    }

    /// Return the key at a given index in the map. The ordering of keys is not
    /// well defined, and this should only be used for enumeration.
    pub fn get_key_at_index(&self, index: U256) -> Option<K> {
        if index >= self.length() {
            return None;
        }
        let mut storage_key = self.length_key().clone();
        storage_key = H256::from(U256::from(storage_key) + index + U256::from(1));
        let storage_value: StorageValue = pwasm_ethereum::read(&storage_key).into();
        Some(storage_value.into())
    }

    /// Insert a value at a given key.
    pub fn insert(&mut self, key: K, value: V) {
        let base = self.base_key(&key);
        self.set_present(&key);
        value.store(self.cap_index, U256::from_big_endian(&base));
        // Increment length
        self.increment_length();
        // Insert the key into the enumeration 'vector'
        let mut length_key = self.length_key().clone();
        length_key = H256::from(U256::from(length_key) + self.length());
        let k_val: StorageValue = key.into();
        write(self.cap_index, &length_key.to_fixed_bytes(), &k_val.into()).unwrap();
    }

    /// Produce an iterator over keys and values.
    pub fn iter(&self) -> StorageEnumerableMapIter<K,V> {
        StorageEnumerableMapIter::new(self)
    }

    /// Produce an iterator over keys.
    pub fn keys(&self) -> StorageEnumerableMapKeys<K,V> {
        StorageEnumerableMapKeys::new(self)
    }

    /// Produce an iterator over values.
    pub fn values(&self) -> StorageEnumerableMapValues<K,V> {
        StorageEnumerableMapValues::new(self)
    }
}


/// An iterator over the values of a [`StorageEnumerableMap`].
pub struct StorageEnumerableMapValues<'a, K, V> {
    /// The StorageVec we are iterating over.
    storage_map: &'a StorageEnumerableMap<K, V>,
    /// The current offset into the StorageVec.
    offset: U256,
}

impl<'a, K: Keyable, V: Storable> StorageEnumerableMapValues<'a, K, V> {
    fn new(storage_map: &'a StorageEnumerableMap<K, V>) -> Self {
        StorageEnumerableMapValues {
            storage_map,
            offset: U256::zero(),
        }
    }
}

impl<'a, K: Keyable, V: Storable> Iterator for StorageEnumerableMapValues<'a, K, V> {
    type Item = V;
    // Needs to be able to enumerate keys

    fn next(&mut self) -> Option<Self::Item> {
        let key = match self.storage_map.get_key_at_index(self.offset) {
            Some(val) => {
                self.offset += U256::from(1);
                Some(val)
            },
            None => None,
        };
        self.storage_map.get(key?)
    }
}

/// An iterator over the keys of a [`StorageEnumerableMap`].
pub struct StorageEnumerableMapKeys<'a, K, V> {
    /// The StorageVec we are iterating over.
    storage_map: &'a StorageEnumerableMap<K, V>,
    /// The current offset into the StorageVec.
    offset: U256,
}

impl<'a, K: Keyable, V: Storable> StorageEnumerableMapKeys<'a, K, V> {
    fn new(storage_map: &'a StorageEnumerableMap<K, V>) -> Self {
        StorageEnumerableMapKeys {
            storage_map,
            offset: U256::zero(),
        }
    }
}

impl<'a, K: Keyable, V: Storable> Iterator for StorageEnumerableMapKeys<'a, K, V> {
    type Item = K;
    // Needs to be able to enumerate keys

    fn next(&mut self) -> Option<Self::Item> {
        let key = match self.storage_map.get_key_at_index(self.offset) {
            Some(val) => {
                self.offset += U256::from(1);
                Some(val)
            },
            None => None,
        };
        key
    }
}

/// An iterator over the keys and values of a [`StorageEnumerableMap`].
pub struct StorageEnumerableMapIter<'a, K, V> {
    /// The StorageVec we are iterating over.
    storage_map: &'a StorageEnumerableMap<K, V>,
    /// The current offset into the StorageVec.
    offset: U256,
}

impl<'a, K: Keyable, V: Storable> StorageEnumerableMapIter<'a, K, V> {
    fn new(storage_map: &'a StorageEnumerableMap<K, V>) -> Self {
        StorageEnumerableMapIter {
            storage_map,
            offset: U256::zero(),
        }
    }
}

impl<'a, K: Keyable, V: Storable> Iterator for StorageEnumerableMapIter<'a, K, V> {
    type Item = (K, V);
    // Needs to be able to enumerate keys

    fn next(&mut self) -> Option<Self::Item> {
        let key = match self.storage_map.get_key_at_index(self.offset) {
            Some(val) => {
                self.offset += U256::from(1);
                val
            },
            None => {
                return None;
            },
        };
        Some((key.clone(), self.storage_map.get(key)?))
    }
}
