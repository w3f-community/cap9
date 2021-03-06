//! This module contains data structures for use with storage and capabilities.
//!
extern crate pwasm_abi;
use pwasm_abi::types::*;
use cap9_core::Serialize;
use cap9_core::StorageValue;

use crate::proc_table;
use crate::syscalls::*;
use crate::*;

use core::marker::PhantomData;

pub mod map;
pub mod map_enumerable;
pub mod vec;


#[derive(Debug)]
pub enum DataStructureError {
    /// There was an alignment error. For example, a map requires a location
    /// starting on a boundary which depends on its key size. Basically the last
    /// key_width+10 bits of the location must be zeroes.
    MisAligned,
    /// There is insufficient room in the cap. This only occurs for data
    /// structures which have a single fixed size which must be satisfied. For
    /// example, a map must be able to store every key in the key space it is
    /// designed for.
    TooSmall,
    /// The data structure was given a capability that is not of the correct
    /// type, or does not exist.
    BadCap,
    /// Miscellaneous other errors, such as divide-by-zero.
    Other,
}

// A type which implements Keyable must follow these rules:
//    1. key width must be 32 or less.
//    2. key_slice() must return a vec with a length of exactly key width.
pub trait Keyable: From<StorageValue> + Into<StorageValue> + Clone {
    /// The width of the key in bytes.
    fn key_width() -> u8;
    fn key_slice(&self) -> Vec<u8>;
}

impl Keyable for u8 {
    fn key_width() -> u8 {
        1
    }

    fn key_slice(&self) -> Vec<u8> {
        let mut v = Vec::new();
        v.push(*self);
        v
    }
}

impl Keyable for Address {
    fn key_width() -> u8 {
        20
    }

    fn key_slice(&self) -> Vec<u8> {
        self.as_bytes().to_vec()
    }
}


/// A value which can be stored in Ethereum storage as a sequence of 32-byte
/// values.
///
/// TODO: we might be able to make this a little more typesafe, currently this
/// is limited to 256 keys.
///
/// Storable inherently has the 32-byte alignment required by storage, but no
/// other alignment requirements. Location is any storage key that leaves enough
/// space.
pub trait Storable: Sized {
    /// Return the number of 32-byte keys required to store a single instance of
    /// this data type.
    fn n_keys() -> U256;

    /// Convert this data into a vector of 32-byte values to be stored.
    fn store(&self, cap_index: u8, location: U256);

    // Clear a value of the given type from storage.
    fn clear(cap_index: u8, location: U256);

    /// Read an instance of this data from storage.
    fn read(location: U256) -> Option<Self>;

    /// Read from a vector of U256.
    fn read_vec_u256(vals: Vec<U256>) -> Option<Self>;
}

impl Storable for u8 {
    fn n_keys() -> U256 {
        1.into()
    }

    // TODO: store is 'unsafe' from a storage point of view
    fn store(&self, cap_index: u8, location: U256) {
        let u: U256 = (*self).into();
        let storage_address: H256 = H256::from(location);
        let value: H256 = u.into();
        write(cap_index, storage_address.as_fixed_bytes(), value.as_fixed_bytes()).unwrap();
    }

    fn clear(cap_index: u8, location: U256) {
        let storage_address: H256 = H256::from(location);
        write(cap_index, storage_address.as_fixed_bytes(), &[0; 32]).unwrap();
    }

    fn read(location: U256) -> Option<Self> {
        let u = pwasm_ethereum::read(&location.into());
        let u: U256 = u.into();
        Some(u.as_u32() as u8)
    }

    fn read_vec_u256(vals: Vec<U256>) -> Option<Self> {
        if vals.len() < 1 {
            None
        } else {
            let u: U256 = vals[0].into();
            Some(u.as_u32() as u8)
        }
    }
}

impl Storable for SysCallProcedureKey {

    fn n_keys() -> U256 {
        1.into()
    }

    fn store(&self, cap_index: u8, location: U256) {
        let storage_address: H256 = H256::from(location);
        let value: H256 = self.into();
        write(cap_index, storage_address.as_fixed_bytes(), value.as_fixed_bytes()).unwrap();
    }

    fn clear(cap_index: u8, location: U256) {
        let storage_address: H256 = H256::from(location);
        write(cap_index, storage_address.as_fixed_bytes(), &[0; 32]).unwrap();
    }

    fn read(location: U256) -> Option<Self> {
        let h: H256 = pwasm_ethereum::read(&location.into()).into();
        Some(h.into())
    }

    fn read_vec_u256(vals: Vec<U256>) -> Option<Self> {
        if vals.len() < 1 {
            None
        } else {
            Some(u256_to_h256(vals[0]).into())
        }
    }
}

fn u256_to_h256(u: U256) -> H256 {
    let mut buf: [u8; 32] = [0; 32];
    u.to_big_endian(&mut buf);
    H256::from_slice(&buf)
}

impl Storable for U256 {

    fn n_keys() -> U256 {
        1.into()
    }

    fn store(&self, cap_index: u8, location: U256) {
        let storage_address: H256 = H256::from(location);
        let value: H256 = self.into();
        write(cap_index, storage_address.as_fixed_bytes(), value.as_fixed_bytes()).unwrap();
    }

    fn clear(cap_index: u8, location: U256) {
        let storage_address: H256 = H256::from(location);
        write(cap_index, storage_address.as_fixed_bytes(), &[0; 32]).unwrap();
    }

    fn read(location: U256) -> Option<Self> {
        let h: H256 = pwasm_ethereum::read(&location.into()).into();
        Some(h.into())
    }

    fn read_vec_u256(vals: Vec<U256>) -> Option<Self> {
        if vals.len() < 1 {
            None
        } else {
            Some(vals[0])
        }
    }

}
