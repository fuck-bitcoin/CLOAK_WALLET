
// helper macros for merkle tree operations
macro_rules! MT_ARR_LEAF_ROW_OFFSET {
    ($d:expr) => ((1<<($d)) - 1)
}
macro_rules! MT_ARR_FULL_TREE_OFFSET {
    ($d:expr) => ((1<<(($d) + 1)) - 1)
}
macro_rules! MT_NUM_LEAVES {
    ($d:expr) => (1<<($d))
}

mod engine;
mod address;
pub mod value;
pub mod circuit;
pub mod constants;
pub mod eosio;
pub mod contract;
pub mod keys;
pub mod note;
pub mod note_encryption;
pub mod pedersen_hash;
pub mod blake2s7r;
pub mod group_hash;
pub mod spec;
pub mod wallet;
pub mod transaction;
pub mod transaction_spend_tests;

use wallet::Wallet;
use crate::address::Address;
use eosio::{Name, Symbol, Asset, Authorization, ExtendedAsset, Transaction, TransactionPacked, ActionPacked, AbiSerialize};
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
use transaction::{ZTransaction, ResolvedZTransaction, resolve_ztransaction, zsign_transaction, zverify_spend_transaction, create_auth_token};
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
use contract::{PlsMintAction, PlsSpendAction, PlsAuthenticateAction, PlsPublishNotesAction, PlsWithdrawAction, PlsFtTransfer};
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
use keys::IncomingViewingKey;
use std::collections::HashMap;
use bellman::groth16::Parameters;
use crate::engine::Bls12;
#[cfg(target_arch = "wasm32")]
use crate::transaction::{MintDesc, zsign_transfer_and_mint_transaction};
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
use std::slice;
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
use std::ffi::CString;
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
use std::ffi::CStr;
#[cfg(target_arch = "wasm32")]
use wasm_bindgen::prelude::*;

use std::cell::RefCell;

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = RefCell::new(None);
}

// Ignore SIGPIPE to prevent crashes when stdout/stderr pipes are closed.
// This is critical for GUI apps that don't have a connected terminal.
#[cfg(any(target_os = "linux", target_os = "macos", target_os = "android"))]
fn ignore_sigpipe() {
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }
}

#[cfg(target_os = "windows")]
fn ignore_sigpipe() {
    // Windows doesn't have SIGPIPE
}

// Call this once at library init
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn caterpillar_init() {
    ignore_sigpipe();
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
fn set_last_error(msg: &str) {
    LAST_ERROR.with(|e| {
        *e.borrow_mut() = Some(msg.to_string());
    });
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_last_error() -> *const libc::c_char {
    LAST_ERROR.with(|e| {
        if let Some(ref msg) = *e.borrow() {
            // allocate a new C string; caller must free with free_string
            CString::new(msg.clone()).unwrap().into_raw()
        } else {
            std::ptr::null()
        }
    })
}

/// The ptr should be a valid pointer to the string allocated by rust
/// source: https://dev.to/kgrech/7-ways-to-pass-a-string-between-rust-and-c-4ieb
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub unsafe extern fn free_string(ptr: *const libc::c_char)
{
    // Take the ownership back to rust and drop the owner
    let _ = CString::from_raw(ptr as *mut _);
}

// generalized log function for use in different targets
// Uses writeln! instead of println! to avoid SIGPIPE crashes when stdout is closed
// (common in GUI apps where stdout isn't connected to a terminal)
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
pub fn log(msg: &str)
{
    use std::io::Write;
    let _ = writeln!(std::io::stdout(), "{}", msg);
}

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen]
extern "C"
{
    // Use `js_namespace` here to bind `console.log(..)` instead of just
    // `log(..)`
    #[wasm_bindgen(js_namespace = console, js_name = log)]
    fn log(s: &str);

    // The `console.log` is quite polymorphic, so we can bind it with multiple
    // signatures. Note that we need to use `js_name` to ensure we always call
    // `log` in JS.
    #[wasm_bindgen(js_namespace = console, js_name = log)]
    fn log_u32(a: u32);

    // Multiple arguments too!
    #[wasm_bindgen(js_namespace = console, js_name = log)]
    fn log_many(a: &str, b: &str);
}

#[cfg(feature = "multicore")]
// see: https://github.com/GoogleChromeLabs/wasm-bindgen-rayon
// only enable this when build as wasm since wasm_bindgen_rayon
// conflicts in build for default target (like for unit tests)
#[cfg(all(target_arch = "wasm32", target_os = "unknown"))]
pub use wasm_bindgen_rayon::init_thread_pool;

// WASM Bindgen Resouces:
// https://rustwasm.github.io/wasm-bindgen/examples/hello-world.html
//
// The following function is for easy use (EOSIO account => ZEOS wallet) in JS Browser applications

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen]
pub fn js_zsign_transfer_and_mint_transaction(
    mint_zactions_json: String,
    alias_authority_json: String,
    user_authority_json: String,
    protocol_contract_json: String,
    fee_token_contract_json: String,
    fees_json: String,
    mint_params_bytes: &[u8]
) -> Result<String, JsError>
{
    log("execute 'zsign_transfer_and_mint_transaction' - this may take a while...");
    let mint_zactions: Vec<MintDesc> = serde_json::from_str(&mint_zactions_json).unwrap();
    let alias_athority = Authorization::from_string(&alias_authority_json).unwrap();
    let user_athority = Authorization::from_string(&user_authority_json).unwrap();
    let protocol_contract = Name::from_string(&protocol_contract_json).unwrap();
    let fee_token_contract = Name::from_string(&fee_token_contract_json).unwrap();
    let fees: HashMap<Name, Asset> = serde_json::from_str(&fees_json).unwrap();
    let mint_params: Parameters<Bls12> = Parameters::<Bls12>::read(mint_params_bytes, false).unwrap();
    Ok(serde_json::to_string(&zsign_transfer_and_mint_transaction(
        &mint_zactions,
        &alias_athority,
        &user_athority,
        protocol_contract,
        fee_token_contract,
        &fees,
        &mint_params
    ).unwrap()).unwrap())
}

// FFI Resources:
// https://gist.github.com/iskakaushik/1c5b8aa75c77479c33c4320913eebef6
// https://jakegoulding.com/rust-ffi-omnibus/objects/
// https://jakegoulding.com/rust-ffi-omnibus/slice_arguments/
// https://dev.to/kgrech/7-ways-to-pass-a-string-between-rust-and-c-4ieb
// https://rust-unofficial.github.io/patterns/idioms/ffi/accepting-strings.html
//
// The following functions are exposed to C via FFI:

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub unsafe extern "C" fn wallet_create(
    seed: *const libc::c_char,
    is_ivk: bool,
    chain_id: *const libc::c_char,
    protocol_contract: *const libc::c_char,
    vault_contract: *const libc::c_char,
    alias_authority: *const libc::c_char,
    out_p_wallet: &mut *mut Wallet,
) -> bool
{
    // Ensure SIGPIPE is ignored (critical for GUI apps without terminal)
    ignore_sigpipe();

    *out_p_wallet = std::ptr::null_mut();

    if seed.is_null() {
        set_last_error("wallet_create: seed is null");
        return false;
    }
    if chain_id.is_null() {
        set_last_error("wallet_create: chain_id is null");
        return false;
    }
    if protocol_contract.is_null() {
        set_last_error("wallet_create: protocol_contract is null");
        return false;
    }
    if vault_contract.is_null() {
        set_last_error("wallet_create: vault_contract is null");
        return false;
    }
    if alias_authority.is_null() {
        set_last_error("wallet_create: alias_authority is null");
        return false;
    }

    let seed_str = match std::ffi::CStr::from_ptr(seed).to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_create: invalid UTF-8 in seed");
            return false;
        }
    };
    let chain_id_str = match std::ffi::CStr::from_ptr(chain_id).to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_create: invalid UTF-8 in chain_id");
            return false;
        }
    };
    let protocol_contract_str = match std::ffi::CStr::from_ptr(protocol_contract).to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_create: invalid UTF-8 in protocol_contract");
            return false;
        }
    };
    let vault_contract_str = match std::ffi::CStr::from_ptr(vault_contract).to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_create: invalid UTF-8 in vault_contract");
            return false;
        }
    };
    let alias_authority_str = match std::ffi::CStr::from_ptr(alias_authority).to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_create: invalid UTF-8 in alias_authority");
            return false;
        }
    };
    let chain_id_vec = match hex::decode(chain_id_str) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("wallet_create: invalid chain_id hex: {e}"));
            return false;
        }
    };
    let chain_id_bytes: [u8; 32] = match chain_id_vec.try_into() {
        Ok(arr) => arr,
        Err(_) => {
            set_last_error("wallet_create: chain_id must decode to 32 bytes");
            return false;
        }
    };

    if is_ivk {
        // Accept IVK (ivk1...) or FVK (fvk1...) — extract IVK from FVK if needed
        let (ivk, fvk_bytes) = if seed_str.starts_with("fvk1") || seed_str.starts_with("fvk") {
            match keys::FullViewingKey::from_bech32m(seed_str) {
                Ok(fvk) => {
                    let bytes = fvk.to_bytes().to_vec();
                    (fvk.ivk(), Some(bytes))
                }
                Err(e) => {
                    set_last_error(&format!("wallet_create: invalid full viewing key: {e}"));
                    return false;
                }
            }
        } else {
            match IncomingViewingKey::from_bech32m(seed_str) {
                Ok(ivk) => (ivk, None),
                Err(e) => {
                    set_last_error(&format!("wallet_create: invalid viewing key: {e}"));
                    return false;
                }
            }
        };
        let protocol_name = match Name::from_string(&protocol_contract_str.to_string()) {
            Ok(n) => n,
            Err(e) => {
                set_last_error(&format!("wallet_create: invalid protocol_contract: {e}"));
                return false;
            }
        };
        let vault_name = match Name::from_string(&vault_contract_str.to_string()) {
            Ok(n) => n,
            Err(e) => {
                set_last_error(&format!("wallet_create: invalid vault_contract: {e}"));
                return false;
            }
        };
        let alias_auth = match Authorization::from_string(&alias_authority_str.to_string()) {
            Ok(a) => a,
            Err(e) => {
                set_last_error(&format!("wallet_create: invalid alias_authority: {e}"));
                return false;
            }
        };
        let wallet_opt = Wallet::create(
            ivk.to_bytes().as_slice(),
            true,
            chain_id_bytes,
            protocol_name,
            vault_name,
            alias_auth,
            fvk_bytes,
        );
        let wallet = match wallet_opt {
            Some(w) => w,
            None => {
                set_last_error("wallet_create: Wallet::create returned None (ivk)");
                return false;
            }
        };

        *out_p_wallet = Box::into_raw(Box::new(wallet));
        true
    } else {
        let protocol_name = match Name::from_string(&protocol_contract_str.to_string()) {
            Ok(n) => n,
            Err(e) => {
                set_last_error(&format!("wallet_create: invalid protocol_contract: {e}"));
                return false;
            }
        };
        let vault_name = match Name::from_string(&vault_contract_str.to_string()) {
            Ok(n) => n,
            Err(e) => {
                set_last_error(&format!("wallet_create: invalid vault_contract: {e}"));
                return false;
            }
        };
        let alias_auth = match Authorization::from_string(&alias_authority_str.to_string()) {
            Ok(a) => a,
            Err(e) => {
                set_last_error(&format!("wallet_create: invalid alias_authority: {e}"));
                return false;
            }
        };
        let wallet_opt = Wallet::create(
            seed_str.as_bytes(),
            false,
            chain_id_bytes,
            protocol_name,
            vault_name,
            alias_auth,
            None,
        );
        let wallet = match wallet_opt {
            Some(w) => w,
            None => {
                set_last_error("wallet_create: Wallet::create returned None (seed)");
                return false;
            }
        };

        *out_p_wallet = Box::into_raw(Box::new(wallet));
        true
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_close(
    p_wallet: *mut Wallet
)
{
    if p_wallet.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(p_wallet));
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_seed_hex(
    p_wallet: *mut Wallet,
    out_seed_hex: &mut *const libc::c_char,
) -> bool {
    if p_wallet.is_null() {
        set_last_error("wallet_seed_hex: p_wallet is null");
        return false;
    }
    let wallet = unsafe { &mut *p_wallet };
    let encoded = hex::encode(wallet.seed());

    match CString::new(encoded) {
        Ok(c_string) => {
            *out_seed_hex = c_string.into_raw(); // transfer ownership to caller
            true
        }
        Err(_) => {
            set_last_error("wallet_seed_hex: CString::new failed (unexpected null byte)");
            *out_seed_hex = std::ptr::null();
            false
        }
    }
}

/// Get the Incoming Viewing Key as bech32m encoded string (ivk1...)
/// This key allows viewing incoming transactions without spending capability.
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_ivk_bech32m(
    p_wallet: *mut Wallet,
    out_ivk: &mut *const libc::c_char,
) -> bool {
    if p_wallet.is_null() {
        set_last_error("wallet_ivk_bech32m: p_wallet is null");
        return false;
    }
    let wallet = unsafe { &mut *p_wallet };

    match wallet.ivk_bech32m() {
        Ok(ivk_str) => {
            match CString::new(ivk_str) {
                Ok(c_string) => {
                    *out_ivk = c_string.into_raw(); // transfer ownership to caller
                    true
                }
                Err(_) => {
                    set_last_error("wallet_ivk_bech32m: CString::new failed (unexpected null byte)");
                    *out_ivk = std::ptr::null();
                    false
                }
            }
        }
        Err(e) => {
            set_last_error(&format!("wallet_ivk_bech32m: bech32 encoding failed: {}", e));
            *out_ivk = std::ptr::null();
            false
        }
    }
}

/// Get the Full Viewing Key as bech32m encoded string (fvk1...)
/// This key allows viewing both incoming AND outgoing transactions.
/// Returns empty string if this is a view-only wallet.
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_fvk_bech32m(
    p_wallet: *mut Wallet,
    out_fvk: &mut *const libc::c_char,
) -> bool {
    if p_wallet.is_null() {
        set_last_error("wallet_fvk_bech32m: p_wallet is null");
        return false;
    }
    let wallet = unsafe { &mut *p_wallet };

    match wallet.fvk_bech32m() {
        Some(Ok(fvk_str)) => {
            match CString::new(fvk_str) {
                Ok(c_string) => {
                    *out_fvk = c_string.into_raw();
                    true
                }
                Err(_) => {
                    set_last_error("wallet_fvk_bech32m: CString::new failed (unexpected null byte)");
                    *out_fvk = std::ptr::null();
                    false
                }
            }
        }
        Some(Err(e)) => {
            set_last_error(&format!("wallet_fvk_bech32m: bech32 encoding failed: {}", e));
            *out_fvk = std::ptr::null();
            false
        }
        None => {
            // View-only wallet, return empty string
            match CString::new("") {
                Ok(c_string) => {
                    *out_fvk = c_string.into_raw();
                    true
                }
                Err(_) => {
                    *out_fvk = std::ptr::null();
                    false
                }
            }
        }
    }
}

/// Get the Outgoing Viewing Key as bech32m encoded string (ovk1...)
/// This key allows viewing outgoing transactions only.
/// Returns empty string if this is a view-only wallet.
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_ovk_bech32m(
    p_wallet: *mut Wallet,
    out_ovk: &mut *const libc::c_char,
) -> bool {
    if p_wallet.is_null() {
        set_last_error("wallet_ovk_bech32m: p_wallet is null");
        return false;
    }
    let wallet = unsafe { &mut *p_wallet };

    match wallet.ovk_bech32m() {
        Some(Ok(ovk_str)) => {
            match CString::new(ovk_str) {
                Ok(c_string) => {
                    *out_ovk = c_string.into_raw();
                    true
                }
                Err(_) => {
                    set_last_error("wallet_ovk_bech32m: CString::new failed (unexpected null byte)");
                    *out_ovk = std::ptr::null();
                    false
                }
            }
        }
        Some(Err(e)) => {
            set_last_error(&format!("wallet_ovk_bech32m: bech32 encoding failed: {}", e));
            *out_ovk = std::ptr::null();
            false
        }
        None => {
            // View-only wallet, return empty string
            match CString::new("") {
                Ok(c_string) => {
                    *out_ovk = c_string.into_raw();
                    true
                }
                Err(_) => {
                    *out_ovk = std::ptr::null();
                    false
                }
            }
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_size(
    p_wallet: *mut Wallet,
    out_size: &mut u64,
) -> bool {
    *out_size = 0;

    if p_wallet.is_null() {
        set_last_error("wallet_size: p_wallet is null");
        return false;
    }
    let wallet = unsafe { &mut *p_wallet };
    *out_size = wallet.size() as u64;
    true
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_is_ivk(
    p_wallet: *mut Wallet,
    out_is_ivk: &mut bool,
) -> bool {
    *out_is_ivk = false;

    if p_wallet.is_null() {
        set_last_error("wallet_is_ivk: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    *out_is_ivk = wallet.is_ivk();
    true
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_chain_id(
    p_wallet: *mut Wallet,
    out_chain_id: &mut *const libc::c_char,
) -> bool {
    *out_chain_id = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_chain_id: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let encoded = hex::encode(wallet.chain_id());

    match CString::new(encoded) {
        Ok(c_string) => {
            *out_chain_id = c_string.into_raw(); // transfer ownership to caller
            true
        }
        Err(_) => {
            set_last_error("wallet_chain_id: CString::new failed (unexpected null byte)");
            *out_chain_id = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_protocol_contract(
    p_wallet: *mut Wallet,
    out_protocol_contract: &mut *const libc::c_char,
) -> bool {
    *out_protocol_contract = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_protocol_contract: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let contract_str = wallet.protocol_contract().to_string();

    match CString::new(contract_str) {
        Ok(c_string) => {
            *out_protocol_contract = c_string.into_raw(); // caller must free with free_string
            true
        }
        Err(_) => {
            set_last_error("wallet_protocol_contract: CString::new failed (unexpected null byte)");
            *out_protocol_contract = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_vault_contract(
    p_wallet: *mut Wallet,
    out_vault_contract: &mut *const libc::c_char,
) -> bool {
    *out_vault_contract = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_vault_contract: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let contract_str = wallet.vault_contract().to_string();

    match CString::new(contract_str) {
        Ok(c_string) => {
            *out_vault_contract = c_string.into_raw(); // caller frees with free_string
            true
        }
        Err(_) => {
            set_last_error("wallet_vault_contract: CString::new failed (unexpected null byte)");
            *out_vault_contract = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_alias_authority(
    p_wallet: *mut Wallet,
    out_alias_authority: &mut *const libc::c_char,
) -> bool {
    *out_alias_authority = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_alias_authority: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let alias_str = wallet.alias_authority().to_string();

    match CString::new(alias_str) {
        Ok(c_string) => {
            *out_alias_authority = c_string.into_raw(); // caller frees with free_string
            true
        }
        Err(_) => {
            set_last_error("wallet_alias_authority: CString::new failed (unexpected null byte)");
            *out_alias_authority = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_block_num(
    p_wallet: *mut Wallet,
    out_block_num: &mut u32,
) -> bool {
    *out_block_num = 0;

    if p_wallet.is_null() {
        set_last_error("wallet_block_num: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    *out_block_num = wallet.block_num();
    true
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_leaf_count(
    p_wallet: *mut Wallet,
    out_leaf_count: &mut u64,
) -> bool {
    *out_leaf_count = 0;

    if p_wallet.is_null() {
        set_last_error("wallet_leaf_count: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    *out_leaf_count = wallet.leaf_count();
    true
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_auth_count(
    p_wallet: *mut Wallet,
    out_auth_count: &mut u64,
) -> bool {
    *out_auth_count = 0;

    if p_wallet.is_null() {
        set_last_error("wallet_auth_count: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    *out_auth_count = wallet.auth_count();
    true
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_set_auth_count(
    p_wallet: *mut Wallet,
    count: u64,
) -> bool {
    if p_wallet.is_null() {
        set_last_error("wallet_set_auth_count: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    wallet.set_auth_count(count);
    true
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_reset_chain_state(
    p_wallet: *mut Wallet,
) -> bool {
    if p_wallet.is_null() {
        set_last_error("wallet_reset_chain_state: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    wallet.reset_chain_state();
    true
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_clear_unpublished_notes(
    p_wallet: *mut Wallet,
) -> bool {
    if p_wallet.is_null() {
        set_last_error("wallet_clear_unpublished_notes: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    wallet.clear_unpublished_notes();
    true
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_write(
    p_wallet: *mut Wallet,
    out_bytes: *mut u8,
) -> bool {
    if p_wallet.is_null() {
        set_last_error("wallet_write: p_wallet is null");
        return false;
    }
    if out_bytes.is_null() {
        set_last_error("wallet_write: out_bytes is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let mut wallet_bytes = Vec::new();
    if let Err(e) = wallet.write(&mut wallet_bytes) {
        set_last_error(&format!("wallet_write: wallet.write failed: {e:?}"));
        return false;
    }

    let expected_size = wallet.size();
    if wallet_bytes.len() != expected_size {
        // This shouldn't normally happen, but let's defend against it.
        set_last_error(&format!(
            "wallet_write: serialized size mismatch (expected {}, got {})",
            expected_size,
            wallet_bytes.len()
        ));
        return false;
    }

    // SAFETY: caller must have allocated at least `wallet_size` bytes at out_bytes.
    unsafe {
        std::ptr::copy_nonoverlapping(wallet_bytes.as_ptr(), out_bytes, wallet_bytes.len());
    }

    true
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_read(
    p_bytes: *const u8,
    len: libc::size_t,
    out_p_wallet: &mut *mut Wallet,
) -> bool {
    *out_p_wallet = std::ptr::null_mut();

    if p_bytes.is_null() {
        set_last_error("wallet_read: p_bytes is null");
        return false;
    }
    if len == 0 {
        set_last_error("wallet_read: len is zero");
        return false;
    }

    // SAFETY: we checked for null and a non-zero length; caller must guarantee
    // that p_bytes points to a valid buffer of at least `len` bytes.
    let bytes: &[u8] = unsafe { slice::from_raw_parts(p_bytes, len as usize) };
    let wallet_res = Wallet::read(bytes);
    let wallet = match wallet_res {
        Ok(w) => w,
        Err(e) => {
            set_last_error(&format!("wallet_read: Wallet::read failed: {e:?}"));
            return false;
        }
    };

    *out_p_wallet = Box::into_raw(Box::new(wallet));
    true
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_json(
    p_wallet: *mut Wallet,
    pretty: bool,
    out_json: &mut *const libc::c_char,
) -> bool {
    *out_json = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_json: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let json = wallet.to_json(pretty);

    match CString::new(json) {
        Ok(c_string) => {
            *out_json = c_string.into_raw(); // caller must free with free_string()
            true
        }
        Err(_) => {
            set_last_error("wallet_json: CString::new failed (unexpected null byte)");
            *out_json = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_balances_json(
    p_wallet: *mut Wallet,
    pretty: bool,
    out_json: &mut *const libc::c_char,
) -> bool {
    *out_json = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_balances_json: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let balances = wallet.balances();
    let json_result = if pretty {
        serde_json::to_string_pretty(&balances)
    } else {
        serde_json::to_string(&balances)
    };
    let json = match json_result {
        Ok(j) => j,
        Err(e) => {
            set_last_error(&format!("wallet_balances_json: serialization failed: {e}"));
            return false;
        }
    };

    match CString::new(json) {
        Ok(c_string) => {
            *out_json = c_string.into_raw(); // caller must free with free_string
            true
        }
        Err(_) => {
            set_last_error("wallet_balances_json: CString::new failed (unexpected null byte)");
            *out_json = std::ptr::null();
            false
        }
    }
}

/// Estimate the total send fee for a given amount, accounting for fragmented notes.
/// Returns the fee in smallest units via out_fee. Returns false on error.
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_estimate_send_fee(
    p_wallet: *mut Wallet,
    send_amount: u64,
    fees_json: *const libc::c_char,
    fee_token_contract_str: *const libc::c_char,
    recipient_addr: *const libc::c_char,
    out_fee: &mut u64,
) -> bool {
    *out_fee = 0;

    if p_wallet.is_null() {
        set_last_error("wallet_estimate_send_fee: p_wallet is null");
        return false;
    }
    if fees_json.is_null() {
        set_last_error("wallet_estimate_send_fee: fees_json is null");
        return false;
    }
    if fee_token_contract_str.is_null() {
        set_last_error("wallet_estimate_send_fee: fee_token_contract_str is null");
        return false;
    }

    let wallet = unsafe { &*p_wallet };

    let fees_json_s: &str = match unsafe { CStr::from_ptr(fees_json) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_estimate_send_fee: invalid UTF-8 in fees_json");
            return false;
        }
    };
    let contract_s: &str = match unsafe { CStr::from_ptr(fee_token_contract_str) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_estimate_send_fee: invalid UTF-8 in fee_token_contract");
            return false;
        }
    };
    // Optional recipient address for self-send detection
    let recipient_opt: Option<&str> = if recipient_addr.is_null() {
        None
    } else {
        match unsafe { CStr::from_ptr(recipient_addr) }.to_str() {
            Ok(s) if !s.is_empty() => Some(s),
            _ => None,
        }
    };

    let fees: HashMap<Name, Asset> = match serde_json::from_str(fees_json_s) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("wallet_estimate_send_fee: invalid fees JSON: {e}"));
            return false;
        }
    };
    let fee_token_contract = match Name::from_string(&contract_s.to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!("wallet_estimate_send_fee: invalid contract name: {e}"));
            return false;
        }
    };

    match wallet.estimate_send_fee(send_amount, &fees, &fee_token_contract, recipient_opt) {
        Some(fee) => {
            *out_fee = fee;
            true
        }
        None => {
            set_last_error("wallet_estimate_send_fee: fee estimation failed");
            false
        }
    }
}

/// Estimate the total burn fee for a vault burn, accounting for fragmented notes.
/// Returns the fee in smallest units via out_fee. Returns false on error.
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_estimate_burn_fee(
    p_wallet: *mut Wallet,
    has_assets: bool,
    fees_json: *const libc::c_char,
    fee_token_contract_str: *const libc::c_char,
    out_fee: &mut u64,
) -> bool {
    *out_fee = 0;

    if p_wallet.is_null() {
        set_last_error("wallet_estimate_burn_fee: p_wallet is null");
        return false;
    }
    if fees_json.is_null() {
        set_last_error("wallet_estimate_burn_fee: fees_json is null");
        return false;
    }
    if fee_token_contract_str.is_null() {
        set_last_error("wallet_estimate_burn_fee: fee_token_contract_str is null");
        return false;
    }

    let wallet = unsafe { &*p_wallet };

    let fees_json_s: &str = match unsafe { CStr::from_ptr(fees_json) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_estimate_burn_fee: invalid UTF-8 in fees_json");
            return false;
        }
    };
    let contract_s: &str = match unsafe { CStr::from_ptr(fee_token_contract_str) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_estimate_burn_fee: invalid UTF-8 in fee_token_contract");
            return false;
        }
    };

    let fees: HashMap<Name, Asset> = match serde_json::from_str(fees_json_s) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("wallet_estimate_burn_fee: invalid fees JSON: {e}"));
            return false;
        }
    };
    let fee_token_contract = match Name::from_string(&contract_s.to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!("wallet_estimate_burn_fee: invalid contract name: {e}"));
            return false;
        }
    };

    match wallet.estimate_burn_fee(has_assets, &fees, &fee_token_contract) {
        Some(fee) => {
            *out_fee = fee;
            true
        }
        None => {
            set_last_error("wallet_estimate_burn_fee: fee estimation failed");
            false
        }
    }
}

/// Estimate vault creation (auth token publish) fee accounting for fragmented notes.
/// Returns the fee in smallest units via out_fee. Returns false on error.
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_estimate_vault_creation_fee(
    p_wallet: *mut Wallet,
    fees_json: *const libc::c_char,
    fee_token_contract_str: *const libc::c_char,
    out_fee: &mut u64,
) -> bool {
    *out_fee = 0;

    if p_wallet.is_null() {
        set_last_error("wallet_estimate_vault_creation_fee: p_wallet is null");
        return false;
    }
    if fees_json.is_null() {
        set_last_error("wallet_estimate_vault_creation_fee: fees_json is null");
        return false;
    }
    if fee_token_contract_str.is_null() {
        set_last_error("wallet_estimate_vault_creation_fee: fee_token_contract_str is null");
        return false;
    }

    let wallet = unsafe { &*p_wallet };

    let fees_json_s: &str = match unsafe { CStr::from_ptr(fees_json) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_estimate_vault_creation_fee: invalid UTF-8 in fees_json");
            return false;
        }
    };
    let contract_s: &str = match unsafe { CStr::from_ptr(fee_token_contract_str) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_estimate_vault_creation_fee: invalid UTF-8 in fee_token_contract");
            return false;
        }
    };

    let fees: HashMap<Name, Asset> = match serde_json::from_str(fees_json_s) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("wallet_estimate_vault_creation_fee: invalid fees JSON: {e}"));
            return false;
        }
    };
    let fee_token_contract = match Name::from_string(&contract_s.to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!("wallet_estimate_vault_creation_fee: invalid contract name: {e}"));
            return false;
        }
    };

    match wallet.estimate_vault_creation_fee(&fees, &fee_token_contract) {
        Some(fee) => {
            *out_fee = fee;
            true
        }
        None => {
            set_last_error("wallet_estimate_vault_creation_fee: fee estimation failed");
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_unspent_notes_json(
    p_wallet: *mut Wallet,
    pretty: bool,
    out_json: &mut *const libc::c_char,
) -> bool {
    *out_json = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_unspent_notes_json: p_wallet is null");
        return false;
    }

    // SAFETY: pointer checked for null; caller must ensure it's a valid Wallet*
    let wallet = unsafe { &mut *p_wallet };
    let unspent = wallet.unspent_notes();
    let json_result = if pretty {
        serde_json::to_string_pretty(&unspent)
    } else {
        serde_json::to_string(&unspent)
    };
    let json = match json_result {
        Ok(j) => j,
        Err(e) => {
            set_last_error(&format!("wallet_unspent_notes_json: serialization failed: {e}"));
            return false;
        }
    };

    match CString::new(json) {
        Ok(c_string) => {
            *out_json = c_string.into_raw(); // caller must free with free_string
            true
        }
        Err(_) => {
            set_last_error("wallet_unspent_notes_json: CString::new failed (unexpected null byte)");
            *out_json = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_fungible_tokens_json(
    p_wallet: *mut Wallet,
    symbol: u64,
    contract: u64,
    pretty: bool,
    out_json: &mut *const libc::c_char,
) -> bool {
    *out_json = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_fungible_tokens_json: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    // Build the list of assets
    let tokens = wallet
        .fungible_tokens(&Symbol(symbol), &Name(contract))
        .iter()
        .map(|n| n.note().asset().clone())
        .collect::<Vec<ExtendedAsset>>();
    let json_result = if pretty {
        serde_json::to_string_pretty(&tokens)
    } else {
        serde_json::to_string(&tokens)
    };
    let json = match json_result {
        Ok(j) => j,
        Err(e) => {
            set_last_error(&format!(
                "wallet_fungible_tokens_json: serialization failed: {e}"
            ));
            return false;
        }
    };

    match CString::new(json) {
        Ok(c_string) => {
            *out_json = c_string.into_raw(); // caller must free with free_string
            true
        }
        Err(_) => {
            set_last_error(
                "wallet_fungible_tokens_json: CString::new failed (unexpected null byte)",
            );
            *out_json = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_non_fungible_tokens_json(
    p_wallet: *mut Wallet,
    contract: u64,
    pretty: bool,
    out_json: &mut *const libc::c_char,
) -> bool {
    *out_json = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_non_fungible_tokens_json: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let tokens = wallet
        .non_fungible_tokens(&Name(contract))
        .iter()
        .map(|n| n.note().asset().clone())
        .collect::<Vec<ExtendedAsset>>();
    let json_result = if pretty {
        serde_json::to_string_pretty(&tokens)
    } else {
        serde_json::to_string(&tokens)
    };
    let json = match json_result {
        Ok(j) => j,
        Err(e) => {
            set_last_error(&format!(
                "wallet_non_fungible_tokens_json: serialization failed: {e}"
            ));
            return false;
        }
    };

    match CString::new(json) {
        Ok(c_string) => {
            *out_json = c_string.into_raw(); // caller must free with free_string
            true
        }
        Err(_) => {
            set_last_error(
                "wallet_non_fungible_tokens_json: CString::new failed (unexpected null byte)",
            );
            *out_json = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_authentication_tokens_json(
    p_wallet: *mut Wallet,
    contract: u64,
    spent: bool,
    seed: bool,
    pretty: bool,
    out_json: &mut *const libc::c_char,
) -> bool {
    *out_json = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_authentication_tokens_json: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let tokens = wallet
        .authentication_tokens(&Name(contract), spent)
        .iter()
        .map(|n| {
            // "<commitment_hex>@<contract_name>|<seed_phrase>"
            if seed {
                format!(
                    "{}@{}|{}",
                    hex::encode(n.note().commitment().to_bytes()),
                    n.note().contract().to_string(),
                    n.note().memo_string()
                )
            // "<commitment_hex>@<contract_name>"
            } else {
                format!(
                    "{}@{}",
                    hex::encode(n.note().commitment().to_bytes()),
                    n.note().contract().to_string()
                )
            }
        })
        .collect::<Vec<String>>();
    let json_result = if pretty {
        serde_json::to_string_pretty(&tokens)
    } else {
        serde_json::to_string(&tokens)
    };
    let json = match json_result {
        Ok(j) => j,
        Err(e) => {
            set_last_error(&format!(
                "wallet_authentication_tokens_json: serialization failed: {e}"
            ));
            return false;
        }
    };

    match CString::new(json) {
        Ok(c_string) => {
            *out_json = c_string.into_raw(); // caller frees with free_string
            true
        }
        Err(_) => {
            set_last_error(
                "wallet_authentication_tokens_json: CString::new failed (unexpected null byte)",
            );
            *out_json = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_unpublished_notes_json(
    p_wallet: *mut Wallet,
    pretty: bool,
    out_json: &mut *const libc::c_char,
) -> bool {
    *out_json = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_unpublished_notes_json: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let unpublished = wallet.unpublished_notes();
    let json_result = if pretty {
        serde_json::to_string_pretty(&unpublished)
    } else {
        serde_json::to_string(&unpublished)
    };
    let json = match json_result {
        Ok(j) => j,
        Err(e) => {
            set_last_error(&format!(
                "wallet_unpublished_notes_json: serialization failed: {e}"
            ));
            return false;
        }
    };

    match CString::new(json) {
        Ok(c_string) => {
            *out_json = c_string.into_raw(); // caller frees with free_string
            true
        }
        Err(_) => {
            set_last_error(
                "wallet_unpublished_notes_json: CString::new failed (unexpected null byte)",
            );
            *out_json = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_transaction_history_json(
    p_wallet: *mut Wallet,
    pretty: bool,
    out_json: &mut *const libc::c_char,
) -> bool {
    *out_json = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_transaction_history_json: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let history = wallet.transaction_history();
    let json_result = if pretty {
        serde_json::to_string_pretty(&history)
    } else {
        serde_json::to_string(&history)
    };
    let json = match json_result {
        Ok(j) => j,
        Err(e) => {
            set_last_error(&format!(
                "wallet_transaction_history_json: serialization failed: {e}"
            ));
            return false;
        }
    };

    match CString::new(json) {
        Ok(c_string) => {
            *out_json = c_string.into_raw(); // caller must free with free_string
            true
        }
        Err(_) => {
            set_last_error(
                "wallet_transaction_history_json: CString::new failed (unexpected null byte)",
            );
            *out_json = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_addresses_json(
    p_wallet: *mut Wallet,
    pretty: bool,
    out_json: &mut *const libc::c_char,
) -> bool {
    *out_json = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_addresses_json: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let addresses = wallet.addresses();
    let json_result = if pretty {
        serde_json::to_string_pretty(&addresses)
    } else {
        serde_json::to_string(&addresses)
    };
    let json = match json_result {
        Ok(j) => j,
        Err(e) => {
            set_last_error(&format!(
                "wallet_addresses_json: serialization failed: {e}"
            ));
            return false;
        }
    };

    match CString::new(json) {
        Ok(c_string) => {
            *out_json = c_string.into_raw(); // caller frees with free_string
            true
        }
        Err(_) => {
            set_last_error(
                "wallet_addresses_json: CString::new failed (unexpected null byte)",
            );
            *out_json = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_default_address(
    p_wallet: *mut Wallet,
    out_address: &mut *const libc::c_char,
) -> bool {
    *out_address = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_default_address: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &*p_wallet };
    let addr = match wallet.default_address() {
        Some(a) => a,
        None => {
            set_last_error("wallet_default_address: could not derive default address");
            return false;
        }
    };
    let bech32m = match addr.to_bech32m() {
        Ok(s) => s,
        Err(e) => {
            set_last_error(&format!("wallet_default_address: bech32m encoding failed: {e}"));
            return false;
        }
    };

    match CString::new(bech32m) {
        Ok(c_string) => {
            *out_address = c_string.into_raw();
            true
        }
        Err(_) => {
            set_last_error("wallet_default_address: CString::new failed");
            *out_address = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_derive_address(
    p_wallet: *mut Wallet,
    out_address: &mut *const libc::c_char,
) -> bool {
    *out_address = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_derive_address: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let addr = wallet.derive_next_address();
    let json = match serde_json::to_string(&addr) {
        Ok(j) => j,
        Err(e) => {
            set_last_error(&format!(
                "wallet_derive_address: serialization failed: {e}"
            ));
            return false;
        }
    };

    match CString::new(json) {
        Ok(c_string) => {
            *out_address = c_string.into_raw(); // caller frees with free_string
            true
        }
        Err(_) => {
            set_last_error(
                "wallet_derive_address: CString::new failed (unexpected null byte)",
            );
            *out_address = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_add_leaves(
    p_wallet: *mut Wallet,
    leaves: *const libc::c_char,
) -> bool {
    if p_wallet.is_null() {
        set_last_error("wallet_add_leaves: p_wallet is null");
        return false;
    }
    if leaves.is_null() {
        set_last_error("wallet_add_leaves: leaves is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let leaves_str: &str = match unsafe { std::ffi::CStr::from_ptr(leaves) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_add_leaves: invalid UTF-8 in leaves");
            return false;
        }
    };
    let bytes = match hex::decode(leaves_str) {
        Ok(b) => b,
        Err(e) => {
            set_last_error(&format!("wallet_add_leaves: invalid hex in leaves: {e}"));
            return false;
        }
    };

    wallet.add_leaves(bytes.as_slice());
    true
}

/// Mark notes as spent by providing on-chain nullifiers.
/// Takes a hex string of concatenated 32-byte nullifier values.
/// Returns the number of notes marked as spent via out_count.
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_add_nullifiers(
    p_wallet: *mut Wallet,
    nullifiers_hex: *const libc::c_char,
    out_count: &mut u64,
) -> bool {
    *out_count = 0;

    if p_wallet.is_null() {
        set_last_error("wallet_add_nullifiers: p_wallet is null");
        return false;
    }
    if nullifiers_hex.is_null() {
        set_last_error("wallet_add_nullifiers: nullifiers_hex is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let hex_str: &str = match unsafe { std::ffi::CStr::from_ptr(nullifiers_hex) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_add_nullifiers: invalid UTF-8");
            return false;
        }
    };

    if hex_str.is_empty() {
        return true; // No nullifiers to process
    }

    let bytes = match hex::decode(hex_str) {
        Ok(b) => b,
        Err(e) => {
            set_last_error(&format!("wallet_add_nullifiers: invalid hex: {e}"));
            return false;
        }
    };

    if bytes.len() % 32 != 0 {
        set_last_error(&format!(
            "wallet_add_nullifiers: hex length {} is not a multiple of 64 (32 bytes per nullifier)",
            hex_str.len()
        ));
        return false;
    }

    // Convert byte chunks to ScalarBytes
    let nullifiers: Vec<contract::ScalarBytes> = bytes
        .chunks(32)
        .map(|chunk| {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(chunk);
            contract::ScalarBytes(arr)
        })
        .collect();

    log(&format!("wallet_add_nullifiers: processing {} nullifiers against {} unspent notes",
        nullifiers.len(), wallet.unspent_notes().len()));

    let count = wallet.mark_notes_spent(&nullifiers);
    *out_count = count as u64;

    log(&format!("wallet_add_nullifiers: marked {} notes as spent", count));
    true
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_add_notes(
    p_wallet: *mut Wallet,
    notes: *const libc::c_char,
    block_num: u32,
    block_ts: u64,
) -> u64 {
    if p_wallet.is_null() {
        set_last_error("wallet_add_notes: p_wallet is null");
        return 0;
    }
    if notes.is_null() {
        set_last_error("wallet_add_notes: notes is null");
        return 0;
    }

    let wallet = unsafe { &mut *p_wallet };
    let notes_str: &str = match unsafe { std::ffi::CStr::from_ptr(notes) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_add_notes: invalid UTF-8 in notes");
            return 0;
        }
    };
    let notes_vec: Vec<String> = match serde_json::from_str(notes_str) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("wallet_add_notes: invalid JSON in notes: {e}"));
            return 0;
        }
    };

    let result = wallet.add_notes(&notes_vec, block_num, block_ts);
    let fts = result & 0xFF;
    let nfts = (result >> 8) & 0xFF;
    let ats = (result >> 16) & 0xFF;
    if fts > 0 || nfts > 0 || ats > 0 {
        log(&format!("wallet_add_notes: block_num={} block_ts={} → decrypted fts={} nfts={} ats={}", block_num, block_ts, fts, nfts, ats));
    }
    result
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_add_unpublished_notes(
    p_wallet: *mut Wallet,
    unpublished_notes: *const libc::c_char,
) -> bool {
    if p_wallet.is_null() {
        set_last_error("wallet_add_unpublished_notes: p_wallet is null");
        return false;
    }
    if unpublished_notes.is_null() {
        set_last_error("wallet_add_unpublished_notes: unpublished_notes is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let unpublished_notes_str: &str =
        match unsafe { std::ffi::CStr::from_ptr(unpublished_notes) }.to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error(
                    "wallet_add_unpublished_notes: invalid UTF-8 in unpublished_notes",
                );
                return false;
            }
        };
    let unpublished_notes_map: HashMap<String, Vec<String>> =
        match serde_json::from_str(unpublished_notes_str) {
            Ok(m) => m,
            Err(e) => {
                set_last_error(&format!(
                    "wallet_add_unpublished_notes: invalid JSON in unpublished_notes: {e}"
                ));
                return false;
            }
        };

    wallet.add_unpublished_notes(&unpublished_notes_map);
    true
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_create_unpublished_auth_note(
    p_wallet: *mut Wallet,
    seed: *const libc::c_char,
    contract: u64,
    address: *const libc::c_char,
    out_unpublished_notes: &mut *const libc::c_char,
) -> bool {
    *out_unpublished_notes = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_create_unpublished_auth_note: p_wallet is null");
        return false;
    }
    if seed.is_null() {
        set_last_error("wallet_create_unpublished_auth_note: seed is null");
        return false;
    }
    if address.is_null() {
        set_last_error("wallet_create_unpublished_auth_note: address is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let seed_str: &str =
        match unsafe { std::ffi::CStr::from_ptr(seed) }.to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error(
                    "wallet_create_unpublished_auth_note: invalid UTF-8 in seed",
                );
                return false;
            }
        };
    let address_str: &str =
        match unsafe { std::ffi::CStr::from_ptr(address) }.to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error(
                    "wallet_create_unpublished_auth_note: invalid UTF-8 in address",
                );
                return false;
            }
        };
    let addr = match Address::from_bech32m(&address_str.to_string()) {
        Ok(a) => a,
        Err(e) => {
            set_last_error(&format!(
                "wallet_create_unpublished_auth_note: invalid bech32m address: {e}"
            ));
            return false;
        }
    };
    let unpublished_notes_map: HashMap<String, Vec<String>> = match create_auth_token(
        wallet,
        seed_str.to_string(),
        Name(contract),
        addr,
    ) {
        Ok(m) => m,
        Err(e) => {
            set_last_error(&format!(
                "wallet_create_unpublished_auth_note: create_auth_token failed: {e:?}"
            ));
            return false;
        }
    };
    let json = match serde_json::to_string(&unpublished_notes_map) {
        Ok(j) => j,
        Err(e) => {
            set_last_error(&format!(
                "wallet_create_unpublished_auth_note: serialization failed: {e}"
            ));
            return false;
        }
    };

    match CString::new(json) {
        Ok(c_string) => {
            *out_unpublished_notes = c_string.into_raw(); // caller frees with free_string
            true
        }
        Err(_) => {
            set_last_error(
                "wallet_create_unpublished_auth_note: CString::new failed (unexpected null byte)",
            );
            *out_unpublished_notes = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_resolve(
    p_wallet: *mut Wallet,
    ztx_json: *const libc::c_char,
    fee_token_contract_json: *const libc::c_char,
    fees_json: *const libc::c_char,
    out_rztx_json: &mut *const libc::c_char,
) -> bool {
    *out_rztx_json = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_resolve: p_wallet is null");
        return false;
    }
    if ztx_json.is_null() {
        set_last_error("wallet_resolve: ztx_json is null");
        return false;
    }
    if fee_token_contract_json.is_null() {
        set_last_error("wallet_resolve: fee_token_contract_json is null");
        return false;
    }
    if fees_json.is_null() {
        set_last_error("wallet_resolve: fees_json is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let ztx_json_str: &str = match unsafe { std::ffi::CStr::from_ptr(ztx_json) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_resolve: invalid UTF-8 in ztx_json");
            return false;
        }
    };
    let fee_token_contract_json_str: &str =
        match unsafe { std::ffi::CStr::from_ptr(fee_token_contract_json) }.to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("wallet_resolve: invalid UTF-8 in fee_token_contract_json");
                return false;
            }
        };
    let fees_json_str: &str =
        match unsafe { std::ffi::CStr::from_ptr(fees_json) }.to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("wallet_resolve: invalid UTF-8 in fees_json");
                return false;
            }
        };
    let fee_token_contract = match Name::from_string(&fee_token_contract_json_str.to_string()) {
        Ok(name) => name,
        Err(e) => {
            set_last_error(&format!(
                "wallet_resolve: invalid fee_token_contract_json: {e}"
            ));
            return false;
        }
    };
    let fees: HashMap<Name, Asset> = match serde_json::from_str(fees_json_str) {
        Ok(f) => f,
        Err(e) => {
            set_last_error(&format!("wallet_resolve: invalid JSON in fees_json: {e}"));
            return false;
        }
    };
    let ztx: ZTransaction = match serde_json::from_str(ztx_json_str) {
        Ok(z) => z,
        Err(e) => {
            set_last_error(&format!("wallet_resolve: invalid JSON in ztx_json: {e}"));
            return false;
        }
    };
    let rztx = match resolve_ztransaction(wallet, &fee_token_contract, &fees, &ztx) {
        Ok(r) => r,
        Err(e) => {
            set_last_error(&format!("wallet_resolve: resolve_ztransaction failed: {e}"));
            return false;
        }
    };
    let json = match serde_json::to_string(&rztx) {
        Ok(j) => j,
        Err(e) => {
            set_last_error(&format!(
                "wallet_resolve: failed to serialize ResolvedZTransaction: {e}"
            ));
            return false;
        }
    };

    match CString::new(json) {
        Ok(c_string) => {
            *out_rztx_json = c_string.into_raw(); // caller must free with free_string
            true
        }
        Err(_) => {
            set_last_error("wallet_resolve: CString::new failed (unexpected null byte)");
            *out_rztx_json = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_zsign(
    p_wallet: *mut Wallet,
    rztx_json: *const libc::c_char,
    p_mint_params_bytes: *const u8,
    mint_params_bytes_len: libc::size_t,
    p_spendoutput_params_bytes: *const u8,
    spendoutput_params_bytes_len: libc::size_t,
    p_spend_params_bytes: *const u8,
    spend_params_bytes_len: libc::size_t,
    p_output_params_bytes: *const u8,
    output_params_bytes_len: libc::size_t,
    out_tx_json: &mut *const libc::c_char,
) -> bool {
    *out_tx_json = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_zsign: p_wallet is null");
        return false;
    }
    if rztx_json.is_null() {
        set_last_error("wallet_zsign: rztx_json is null");
        return false;
    }
    if p_mint_params_bytes.is_null() {
        set_last_error("wallet_zsign: p_mint_params_bytes is null");
        return false;
    }
    if p_spendoutput_params_bytes.is_null() {
        set_last_error("wallet_zsign: p_spendoutput_params_bytes is null");
        return false;
    }
    if p_spend_params_bytes.is_null() {
        set_last_error("wallet_zsign: p_spend_params_bytes is null");
        return false;
    }
    if p_output_params_bytes.is_null() {
        set_last_error("wallet_zsign: p_output_params_bytes is null");
        return false;
    }
    if mint_params_bytes_len == 0
        || spendoutput_params_bytes_len == 0
        || spend_params_bytes_len == 0
        || output_params_bytes_len == 0
    {
        set_last_error("wallet_zsign: one or more params byte slices have length 0");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let rztx_json_str: &str =
        match unsafe { std::ffi::CStr::from_ptr(rztx_json) }.to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("wallet_zsign: invalid UTF-8 in rztx_json");
                return false;
            }
        };
    let mint_params_bytes: &[u8] = unsafe {
        slice::from_raw_parts(p_mint_params_bytes, mint_params_bytes_len as usize)
    };
    let spendoutput_params_bytes: &[u8] = unsafe {
        slice::from_raw_parts(p_spendoutput_params_bytes, spendoutput_params_bytes_len as usize)
    };
    let spend_params_bytes: &[u8] = unsafe {
        slice::from_raw_parts(p_spend_params_bytes, spend_params_bytes_len as usize)
    };
    let output_params_bytes: &[u8] = unsafe {
        slice::from_raw_parts(p_output_params_bytes, output_params_bytes_len as usize)
    };
    let mut params = HashMap::new();
    let mint_name = match Name::from_string(&"mint".to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!("wallet_zsign: failed to construct Name(\"mint\"): {e}"));
            return false;
        }
    };
    let spendoutput_name = match Name::from_string(&"spendoutput".to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!(
                "wallet_zsign: failed to construct Name(\"spendoutput\"): {e}"
            ));
            return false;
        }
    };
    let spend_name = match Name::from_string(&"spend".to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!("wallet_zsign: failed to construct Name(\"spend\"): {e}"));
            return false;
        }
    };
    let output_name = match Name::from_string(&"output".to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!("wallet_zsign: failed to construct Name(\"output\"): {e}"));
            return false;
        }
    };
    let mint_params = match Parameters::<Bls12>::read(mint_params_bytes, false) {
        Ok(p) => p,
        Err(e) => {
            set_last_error(&format!("wallet_zsign: failed to read mint params: {e:?}"));
            return false;
        }
    };
    let spendoutput_params =
        match Parameters::<Bls12>::read(spendoutput_params_bytes, false) {
            Ok(p) => p,
            Err(e) => {
                set_last_error(&format!(
                    "wallet_zsign: failed to read spendoutput params: {e:?}"
                ));
                return false;
            }
        };
    let spend_params = match Parameters::<Bls12>::read(spend_params_bytes, false) {
        Ok(p) => p,
        Err(e) => {
            set_last_error(&format!("wallet_zsign: failed to read spend params: {e:?}"));
            return false;
        }
    };
    let output_params = match Parameters::<Bls12>::read(output_params_bytes, false) {
        Ok(p) => p,
        Err(e) => {
            set_last_error(&format!("wallet_zsign: failed to read output params: {e:?}"));
            return false;
        }
    };
    params.insert(mint_name, mint_params);
    params.insert(spendoutput_name, spendoutput_params);
    params.insert(spend_name, spend_params);
    params.insert(output_name, output_params);
    let rztx: ResolvedZTransaction = match serde_json::from_str(rztx_json_str) {
        Ok(r) => r,
        Err(e) => {
            set_last_error(&format!("wallet_zsign: invalid JSON in rztx_json: {e}"));
            return false;
        }
    };
    let tx = match zsign_transaction(wallet, &rztx, &params) {
        Ok(t) => t,
        Err(e) => {
            set_last_error(&format!("wallet_zsign: zsign_transaction failed: {e:?}"));
            return false;
        }
    };
    let json = match serde_json::to_string(&tx) {
        Ok(j) => j,
        Err(e) => {
            set_last_error(&format!("wallet_zsign: failed to serialize transaction: {e}"));
            return false;
        }
    };

    match CString::new(json) {
        Ok(c_string) => {
            *out_tx_json = c_string.into_raw(); // caller must free with free_string
            true
        }
        Err(_) => {
            set_last_error(
                "wallet_zsign: CString::new failed (unexpected null byte in JSON)",
            );
            *out_tx_json = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_zverify_spend(
    tx_json: *const libc::c_char,
    p_spendoutput_params_bytes: *const u8,
    spendoutput_params_bytes_len: libc::size_t,
    p_spend_params_bytes: *const u8,
    spend_params_bytes_len: libc::size_t,
    p_output_params_bytes: *const u8,
    output_params_bytes_len: libc::size_t,
    out_is_valid: &mut bool,
) -> bool {
    *out_is_valid = false;

    if tx_json.is_null() {
        set_last_error("wallet_zverify_spend: tx_json is null");
        return false;
    }
    if p_spendoutput_params_bytes.is_null() {
        set_last_error("wallet_zverify_spend: p_spendoutput_params_bytes is null");
        return false;
    }
    if p_spend_params_bytes.is_null() {
        set_last_error("wallet_zverify_spend: p_spend_params_bytes is null");
        return false;
    }
    if p_output_params_bytes.is_null() {
        set_last_error("wallet_zverify_spend: p_output_params_bytes is null");
        return false;
    }
    if spendoutput_params_bytes_len == 0
        || spend_params_bytes_len == 0
        || output_params_bytes_len == 0
    {
        set_last_error("wallet_zverify_spend: one or more params byte slices have length 0");
        return false;
    }

    let tx_json_str: &str =
        match unsafe { std::ffi::CStr::from_ptr(tx_json) }.to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("wallet_zverify_spend: invalid UTF-8 in tx_json");
                return false;
            }
        };

    let spendoutput_params_bytes: &[u8] = unsafe {
        slice::from_raw_parts(
            p_spendoutput_params_bytes,
            spendoutput_params_bytes_len as usize,
        )
    };
    let spend_params_bytes: &[u8] = unsafe {
        slice::from_raw_parts(p_spend_params_bytes, spend_params_bytes_len as usize)
    };
    let output_params_bytes: &[u8] = unsafe {
        slice::from_raw_parts(p_output_params_bytes, output_params_bytes_len as usize)
    };
    let mut params = HashMap::new();
    let spendoutput_name = match Name::from_string(&"spendoutput".to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!(
                "wallet_zverify_spend: failed to construct Name(\"spendoutput\"): {e}"
            ));
            return false;
        }
    };
    let spend_name = match Name::from_string(&"spend".to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!(
                "wallet_zverify_spend: failed to construct Name(\"spend\"): {e}"
            ));
            return false;
        }
    };
    let output_name = match Name::from_string(&"output".to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!(
                "wallet_zverify_spend: failed to construct Name(\"output\"): {e}"
            ));
            return false;
        }
    };
    let spendoutput_params = match Parameters::<Bls12>::read(spendoutput_params_bytes, false) {
        Ok(p) => p,
        Err(e) => {
            set_last_error(&format!(
                "wallet_zverify_spend: failed to read spendoutput params: {e:?}"
            ));
            return false;
        }
    };
    let spend_params = match Parameters::<Bls12>::read(spend_params_bytes, false) {
        Ok(p) => p,
        Err(e) => {
            set_last_error(&format!(
                "wallet_zverify_spend: failed to read spend params: {e:?}"
            ));
            return false;
        }
    };
    let output_params = match Parameters::<Bls12>::read(output_params_bytes, false) {
        Ok(p) => p,
        Err(e) => {
            set_last_error(&format!(
                "wallet_zverify_spend: failed to read output params: {e:?}"
            ));
            return false;
        }
    };
    params.insert(spendoutput_name, spendoutput_params);
    params.insert(spend_name, spend_params);
    params.insert(output_name, output_params);
    let tx: Transaction = match serde_json::from_str(tx_json_str) {
        Ok(t) => t,
        Err(e) => {
            set_last_error(&format!("wallet_zverify_spend: invalid JSON in tx_json: {e}"));
            return false;
        }
    };

    *out_is_valid = zverify_spend_transaction(&tx, &params).is_ok();
    true
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_transact(
    p_wallet: *mut Wallet,
    ztx_json: *const libc::c_char,
    fee_token_contract_json: *const libc::c_char,
    fees_json: *const libc::c_char,
    p_mint_params_bytes: *const u8,
    mint_params_bytes_len: libc::size_t,
    p_spendoutput_params_bytes: *const u8,
    spendoutput_params_bytes_len: libc::size_t,
    p_spend_params_bytes: *const u8,
    spend_params_bytes_len: libc::size_t,
    p_output_params_bytes: *const u8,
    output_params_bytes_len: libc::size_t,
    out_tx_json: &mut *const libc::c_char,
) -> bool {
    *out_tx_json = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_transact: p_wallet is null");
        return false;
    }
    if ztx_json.is_null() {
        set_last_error("wallet_transact: ztx_json is null");
        return false;
    }
    if fee_token_contract_json.is_null() {
        set_last_error("wallet_transact: fee_token_contract_json is null");
        return false;
    }
    if fees_json.is_null() {
        set_last_error("wallet_transact: fees_json is null");
        return false;
    }
    if p_mint_params_bytes.is_null() {
        set_last_error("wallet_transact: p_mint_params_bytes is null");
        return false;
    }
    if p_spendoutput_params_bytes.is_null() {
        set_last_error("wallet_transact: p_spendoutput_params_bytes is null");
        return false;
    }
    if p_spend_params_bytes.is_null() {
        set_last_error("wallet_transact: p_spend_params_bytes is null");
        return false;
    }
    if p_output_params_bytes.is_null() {
        set_last_error("wallet_transact: p_output_params_bytes is null");
        return false;
    }
    if mint_params_bytes_len == 0
        || spendoutput_params_bytes_len == 0
        || spend_params_bytes_len == 0
        || output_params_bytes_len == 0
    {
        set_last_error("wallet_transact: one or more params byte slices have length 0");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let ztx_json_str: &str =
        match unsafe { std::ffi::CStr::from_ptr(ztx_json) }.to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("wallet_transact: invalid UTF-8 in ztx_json");
                return false;
            }
        };
    let fee_token_contract_json_str: &str = match unsafe {
        std::ffi::CStr::from_ptr(fee_token_contract_json)
    }
    .to_str()
    {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_transact: invalid UTF-8 in fee_token_contract_json");
            return false;
        }
    };
    let fees_json_str: &str =
        match unsafe { std::ffi::CStr::from_ptr(fees_json) }.to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("wallet_transact: invalid UTF-8 in fees_json");
                return false;
            }
        };
    let mint_params_bytes: &[u8] = unsafe {
        slice::from_raw_parts(p_mint_params_bytes, mint_params_bytes_len as usize)
    };
    let spendoutput_params_bytes: &[u8] = unsafe {
        slice::from_raw_parts(
            p_spendoutput_params_bytes,
            spendoutput_params_bytes_len as usize,
        )
    };
    let spend_params_bytes: &[u8] = unsafe {
        slice::from_raw_parts(p_spend_params_bytes, spend_params_bytes_len as usize)
    };
    let output_params_bytes: &[u8] = unsafe {
        slice::from_raw_parts(p_output_params_bytes, output_params_bytes_len as usize)
    };
    let fee_token_contract = match Name::from_string(&fee_token_contract_json_str.to_string()) {
        Ok(name) => name,
        Err(e) => {
            set_last_error(&format!(
                "wallet_transact: invalid fee_token_contract_json: {e}"
            ));
            return false;
        }
    };
    let fees = match serde_json::from_str(fees_json_str) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("wallet_transact: invalid JSON in fees_json: {e}"));
            return false;
        }
    };
    let mut params = HashMap::new();
    let mint_name = match Name::from_string(&"mint".to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!("wallet_transact: Name(\"mint\") failed: {e}"));
            return false;
        }
    };
    let spendoutput_name = match Name::from_string(&"spendoutput".to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!(
                "wallet_transact: Name(\"spendoutput\") failed: {e}"
            ));
            return false;
        }
    };
    let spend_name = match Name::from_string(&"spend".to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!("wallet_transact: Name(\"spend\") failed: {e}"));
            return false;
        }
    };
    let output_name = match Name::from_string(&"output".to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!("wallet_transact: Name(\"output\") failed: {e}"));
            return false;
        }
    };
    let mint_params = match Parameters::<Bls12>::read(mint_params_bytes, false) {
        Ok(p) => p,
        Err(e) => {
            set_last_error(&format!("wallet_transact: failed to read mint params: {e:?}"));
            return false;
        }
    };
    let spendoutput_params =
        match Parameters::<Bls12>::read(spendoutput_params_bytes, false) {
            Ok(p) => p,
            Err(e) => {
                set_last_error(&format!(
                    "wallet_transact: failed to read spendoutput params: {e:?}"
                ));
                return false;
            }
        };
    let spend_params = match Parameters::<Bls12>::read(spend_params_bytes, false) {
        Ok(p) => p,
        Err(e) => {
            set_last_error(&format!(
                "wallet_transact: failed to read spend params: {e:?}"
            ));
            return false;
        }
    };
    let output_params = match Parameters::<Bls12>::read(output_params_bytes, false) {
        Ok(p) => p,
        Err(e) => {
            set_last_error(&format!(
                "wallet_transact: failed to read output params: {e:?}"
            ));
            return false;
        }
    };
    params.insert(mint_name, mint_params);
    params.insert(spendoutput_name, spendoutput_params);
    params.insert(spend_name, spend_params);
    params.insert(output_name, output_params);
    let ztx: ZTransaction = match serde_json::from_str(ztx_json_str) {
        Ok(z) => z,
        Err(e) => {
            set_last_error(&format!("wallet_transact: invalid JSON in ztx_json: {e}"));
            return false;
        }
    };
    let rztx = match resolve_ztransaction(wallet, &fee_token_contract, &fees, &ztx) {
        Ok(r) => r,
        Err(e) => {
            set_last_error(&format!("wallet_transact: resolve_ztransaction failed: {e:?}"));
            return false;
        }
    };
    let tx = match zsign_transaction(wallet, &rztx, &params) {
        Ok(t) => t,
        Err(e) => {
            set_last_error(&format!("wallet_transact: zsign_transaction failed: {e:?}"));
            return false;
        }
    };
    let json = match serde_json::to_string(&tx) {
        Ok(j) => j,
        Err(e) => {
            set_last_error(&format!(
                "wallet_transact: failed to serialize transaction: {e}"
            ));
            return false;
        }
    };

    match CString::new(json) {
        Ok(c_string) => {
            *out_tx_json = c_string.into_raw(); // caller must free with free_string
            true
        }
        Err(_) => {
            set_last_error(
                "wallet_transact: CString::new failed (unexpected null byte in JSON)",
            );
            *out_tx_json = std::ptr::null();
            false
        }
    }
}

/// Convert Action to ActionPacked by serializing the action data to ABI binary format
/// Returns None if the action type is not recognized or serialization fails
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
fn action_to_packed(action: &eosio::Action) -> Option<ActionPacked> {
    // Serialize action data based on action name
    let hex_data = match action.name.to_string().as_str() {
        "begin" | "end" => {
            // Empty action data
            String::new()
        }
        "mint" => {
            // PlsMintAction
            let mint_action: PlsMintAction = serde_json::from_value(action.data.clone()).ok()?;
            hex::encode(mint_action.abi_serialize())
        }
        "spend" => {
            // PlsSpendAction
            let spend_action: PlsSpendAction = serde_json::from_value(action.data.clone()).ok()?;
            hex::encode(spend_action.abi_serialize())
        }
        "authenticate" => {
            // PlsAuthenticateAction
            let auth_action: PlsAuthenticateAction = serde_json::from_value(action.data.clone()).ok()?;
            hex::encode(auth_action.abi_serialize())
        }
        "publishnotes" => {
            // PlsPublishNotesAction
            let publish_action: PlsPublishNotesAction = serde_json::from_value(action.data.clone()).ok()?;
            hex::encode(publish_action.abi_serialize())
        }
        "withdraw" => {
            // PlsWithdrawAction
            let withdraw_action: PlsWithdrawAction = serde_json::from_value(action.data.clone()).ok()?;
            hex::encode(withdraw_action.abi_serialize())
        }
        "transfer" => {
            // PlsFtTransfer (standard eosio.token transfer)
            let transfer: PlsFtTransfer = serde_json::from_value(action.data.clone()).ok()?;
            hex::encode(transfer.abi_serialize())
        }
        _ => {
            // Unknown action type - try to serialize as-is (may fail)
            // For safety, return empty hex_data
            log(&format!("Warning: Unknown action type '{}', hex_data will be empty", action.name.to_string()));
            String::new()
        }
    };

    Some(ActionPacked {
        account: action.account.clone(),
        name: action.name.clone(),
        authorization: action.authorization.clone(),
        data: action.data.clone(),
        hex_data,
    })
}

/// Convert a Transaction to TransactionPacked
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
fn transaction_to_packed(tx: &Transaction) -> Result<TransactionPacked, String> {
    let mut packed_actions = Vec::new();
    for action in &tx.actions {
        match action_to_packed(action) {
            Some(packed) => packed_actions.push(packed),
            None => return Err(format!("Failed to serialize action: {}::{}",
                action.account.to_string(), action.name.to_string())),
        }
    }
    Ok(TransactionPacked { actions: packed_actions })
}

/// Like wallet_transact but returns actions with hex_data for ABI-serialized binary data.
/// This is needed for ESR (EOSIO Signing Request) which requires properly serialized action data.
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_transact_packed(
    p_wallet: *mut Wallet,
    ztx_json: *const libc::c_char,
    fee_token_contract_json: *const libc::c_char,
    fees_json: *const libc::c_char,
    p_mint_params_bytes: *const u8,
    mint_params_bytes_len: libc::size_t,
    p_spendoutput_params_bytes: *const u8,
    spendoutput_params_bytes_len: libc::size_t,
    p_spend_params_bytes: *const u8,
    spend_params_bytes_len: libc::size_t,
    p_output_params_bytes: *const u8,
    output_params_bytes_len: libc::size_t,
    out_tx_json: &mut *const libc::c_char,
) -> bool {
    *out_tx_json = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_transact_packed: p_wallet is null");
        return false;
    }
    if ztx_json.is_null() {
        set_last_error("wallet_transact_packed: ztx_json is null");
        return false;
    }
    if fee_token_contract_json.is_null() {
        set_last_error("wallet_transact_packed: fee_token_contract_json is null");
        return false;
    }
    if fees_json.is_null() {
        set_last_error("wallet_transact_packed: fees_json is null");
        return false;
    }
    if p_mint_params_bytes.is_null() {
        set_last_error("wallet_transact_packed: p_mint_params_bytes is null");
        return false;
    }
    if p_spendoutput_params_bytes.is_null() {
        set_last_error("wallet_transact_packed: p_spendoutput_params_bytes is null");
        return false;
    }
    if p_spend_params_bytes.is_null() {
        set_last_error("wallet_transact_packed: p_spend_params_bytes is null");
        return false;
    }
    if p_output_params_bytes.is_null() {
        set_last_error("wallet_transact_packed: p_output_params_bytes is null");
        return false;
    }
    if mint_params_bytes_len == 0
        || spendoutput_params_bytes_len == 0
        || spend_params_bytes_len == 0
        || output_params_bytes_len == 0
    {
        set_last_error("wallet_transact_packed: one or more params byte slices have length 0");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let ztx_json_str: &str =
        match unsafe { std::ffi::CStr::from_ptr(ztx_json) }.to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("wallet_transact_packed: invalid UTF-8 in ztx_json");
                return false;
            }
        };
    let fee_token_contract_json_str: &str = match unsafe {
        std::ffi::CStr::from_ptr(fee_token_contract_json)
    }
    .to_str()
    {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_transact_packed: invalid UTF-8 in fee_token_contract_json");
            return false;
        }
    };
    let fees_json_str: &str =
        match unsafe { std::ffi::CStr::from_ptr(fees_json) }.to_str() {
            Ok(s) => s,
            Err(_) => {
                set_last_error("wallet_transact_packed: invalid UTF-8 in fees_json");
                return false;
            }
        };
    let mint_params_bytes: &[u8] = unsafe {
        slice::from_raw_parts(p_mint_params_bytes, mint_params_bytes_len as usize)
    };
    let spendoutput_params_bytes: &[u8] = unsafe {
        slice::from_raw_parts(
            p_spendoutput_params_bytes,
            spendoutput_params_bytes_len as usize,
        )
    };
    let spend_params_bytes: &[u8] = unsafe {
        slice::from_raw_parts(p_spend_params_bytes, spend_params_bytes_len as usize)
    };
    let output_params_bytes: &[u8] = unsafe {
        slice::from_raw_parts(p_output_params_bytes, output_params_bytes_len as usize)
    };
    let fee_token_contract = match Name::from_string(&fee_token_contract_json_str.to_string()) {
        Ok(name) => name,
        Err(e) => {
            set_last_error(&format!(
                "wallet_transact_packed: invalid fee_token_contract_json: {e}"
            ));
            return false;
        }
    };
    let fees: HashMap<Name, Asset> = match serde_json::from_str(fees_json_str) {
        Ok(v) => v,
        Err(e) => {
            set_last_error(&format!("wallet_transact_packed: invalid JSON in fees_json: {e}"));
            return false;
        }
    };
    // Debug: Check fees map contents
    let begin_name = Name::from_string(&"begin".to_string()).unwrap();
    if !fees.contains_key(&begin_name) {
        // List all keys in the map for debugging
        let keys: Vec<String> = fees.keys().map(|k| k.to_string()).collect();
        set_last_error(&format!(
            "wallet_transact_packed: 'begin' not in fees map. Map has {} entries, keys: {:?}, JSON was: {}",
            fees.len(), keys, fees_json_str
        ));
        return false;
    }
    let mut params = HashMap::new();
    let mint_name = match Name::from_string(&"mint".to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!("wallet_transact_packed: Name(\"mint\") failed: {e}"));
            return false;
        }
    };
    let spendoutput_name = match Name::from_string(&"spendoutput".to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!(
                "wallet_transact_packed: Name(\"spendoutput\") failed: {e}"
            ));
            return false;
        }
    };
    let spend_name = match Name::from_string(&"spend".to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!("wallet_transact_packed: Name(\"spend\") failed: {e}"));
            return false;
        }
    };
    let output_name = match Name::from_string(&"output".to_string()) {
        Ok(n) => n,
        Err(e) => {
            set_last_error(&format!("wallet_transact_packed: Name(\"output\") failed: {e}"));
            return false;
        }
    };
    let mint_params = match Parameters::<Bls12>::read(mint_params_bytes, false) {
        Ok(p) => p,
        Err(e) => {
            set_last_error(&format!("wallet_transact_packed: failed to read mint params: {e:?}"));
            return false;
        }
    };
    let spendoutput_params =
        match Parameters::<Bls12>::read(spendoutput_params_bytes, false) {
            Ok(p) => p,
            Err(e) => {
                set_last_error(&format!(
                    "wallet_transact_packed: failed to read spendoutput params: {e:?}"
                ));
                return false;
            }
        };
    let spend_params = match Parameters::<Bls12>::read(spend_params_bytes, false) {
        Ok(p) => p,
        Err(e) => {
            set_last_error(&format!(
                "wallet_transact_packed: failed to read spend params: {e:?}"
            ));
            return false;
        }
    };
    let output_params = match Parameters::<Bls12>::read(output_params_bytes, false) {
        Ok(p) => p,
        Err(e) => {
            set_last_error(&format!(
                "wallet_transact_packed: failed to read output params: {e:?}"
            ));
            return false;
        }
    };
    params.insert(mint_name, mint_params);
    params.insert(spendoutput_name, spendoutput_params);
    params.insert(spend_name, spend_params);
    params.insert(output_name, output_params);
    let ztx: ZTransaction = match serde_json::from_str(ztx_json_str) {
        Ok(z) => z,
        Err(e) => {
            set_last_error(&format!("wallet_transact_packed: invalid JSON in ztx_json: {e}"));
            return false;
        }
    };
    let rztx = match resolve_ztransaction(wallet, &fee_token_contract, &fees, &ztx) {
        Ok(r) => r,
        Err(e) => {
            set_last_error(&format!("wallet_transact_packed: resolve_ztransaction failed: {e:?}"));
            return false;
        }
    };
    let (tx, meta) = match zsign_transaction(wallet, &rztx, &params) {
        Ok(t) => t,
        Err(e) => {
            set_last_error(&format!("wallet_transact_packed: zsign_transaction failed: {e:?}"));
            return false;
        }
    };

    // Verify proofs locally before submitting to chain
    if let Err(e) = zverify_spend_transaction(&tx, &params) {
        set_last_error(&format!("wallet_transact_packed: LOCAL proof verification FAILED: {:?}", e));
        return false;
    }

    // ---- Eagerly update wallet state so balance/history reflect the send immediately ----
    // zsign_transaction takes &Wallet (immutable), so the wallet state is unchanged after
    // signing. Without this eager update, the wallet depends entirely on the next sync
    // cycle, which can cause a temporary balance drop (spent inputs still counted,
    // change notes not yet tracked).
    //
    // Strategy:
    // 1. Insert output commitments into the local merkle tree (so add_notes can find leaves)
    // 2. Mark spent input notes via nullifiers
    // 3. Call add_notes() on note ciphertexts — receiver decryption adds change notes to
    //    unspent_notes (with correct tree position), sender decryption adds to outgoing_notes
    //    (for TX history)
    // 4. Store as unpublished_notes for redundancy (retried on each digest_block)
    {
        // Step 1: Insert output commitments as merkle tree leaves.
        // The on-chain contract adds these as leaves when the TX is processed:
        //   - cm_b from each spend_output (change notes)
        //   - cm from each output (recipient notes)
        let mut leaf_bytes: Vec<u8> = Vec::new();
        let mut all_note_cts: Vec<String> = Vec::new();
        for action in tx.actions.iter() {
            if action.name == Name(14219329122852667392) { // spend
                if let Ok(data) = serde_json::from_value::<PlsSpendAction>(action.data.clone()) {
                    for seq in data.actions.iter() {
                        for so in seq.spend_output.iter() {
                            leaf_bytes.extend_from_slice(&so.cm_b.0);
                        }
                        for o in seq.output.iter() {
                            leaf_bytes.extend_from_slice(&o.cm.0);
                        }
                    }
                    all_note_cts.extend(data.note_ct.iter().cloned());
                }
            }
            if action.name == Name(12578297992662373760) { // publishnotes
                if let Ok(data) = serde_json::from_value::<PlsPublishNotesAction>(action.data.clone()) {
                    all_note_cts.extend(data.note_ct.iter().cloned());
                }
            }
            if action.name == Name(10639630974360485888) { // mint
                if let Ok(data) = serde_json::from_value::<PlsMintAction>(action.data.clone()) {
                    for m in data.actions.iter() {
                        leaf_bytes.extend_from_slice(&m.cm.0);
                    }
                    all_note_cts.extend(data.note_ct.iter().cloned());
                }
            }
        }
        if !leaf_bytes.is_empty() {
            wallet.add_leaves(&leaf_bytes);
        }

        // Step 2: Mark spent input notes via nullifiers from the signed transaction.
        {
            let sk = keys::SpendingKey::from_seed(&wallet.seed());
            let fvk = keys::FullViewingKey::from_spending_key(&sk);
            for action in tx.actions.iter() {
                if action.name == Name(14219329122852667392) { // spend
                    if let Ok(data) = serde_json::from_value::<PlsSpendAction>(action.data.clone()) {
                        for seq in data.actions.iter() {
                            for so in seq.spend_output.iter() {
                                if let Ok(nf_scalar) = crate::engine::Scalar::try_from(so.nf.clone()) {
                                    // Search backwards since remove() shifts indices
                                    for i in (0..wallet.unspent_notes().len()).rev() {
                                        // Skip auth tokens — they have no merkle tree position and no on-chain nullifiers
                                        if wallet.unspent_notes()[i].note().is_auth_token() { continue; }
                                        let note_nf = wallet.unspent_notes()[i].note()
                                            .nullifier(&fvk.nk, wallet.unspent_notes()[i].position())
                                            .extract().0;
                                        if note_nf.eq(&nf_scalar) {
                                            wallet.mark_note_spent(i);
                                            break;
                                        }
                                    }
                                }
                            }
                            for s in seq.spend.iter() {
                                if let Ok(nf_scalar) = crate::engine::Scalar::try_from(s.nf.clone()) {
                                    for i in (0..wallet.unspent_notes().len()).rev() {
                                        // Skip auth tokens — they have no merkle tree position and no on-chain nullifiers
                                        if wallet.unspent_notes()[i].note().is_auth_token() { continue; }
                                        let note_nf = wallet.unspent_notes()[i].note()
                                            .nullifier(&fvk.nk, wallet.unspent_notes()[i].position())
                                            .extract().0;
                                        if note_nf.eq(&nf_scalar) {
                                            wallet.mark_note_spent(i);
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Compute block_ts ONCE for both Step 2b and Step 3.
        // Using a single timestamp ensures the burned auth token and fee notes
        // share the same block_ts, so transaction_history() can correctly populate
        // burn_timestamps and label fee-only entries as "Burn Vault".
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        let max_ts = wallet.max_block_ts();
        let block_ts = std::cmp::max(now_ms, max_ts.saturating_add(1));

        // Step 2b: Handle burned auth tokens (burn=1 authenticate).
        // Auth tokens have no on-chain nullifiers, so Step 2 skips them.
        // We must explicitly move burned auth tokens to spent+outgoing
        // so transaction_history() can label them as "Burn Vault".
        if !meta.auth_tokens.spent.is_empty() {
            for token_id in meta.auth_tokens.spent.iter() {
                // token_id format: "<cm_hex>@<contract>"
                if let Some(cm_hex) = token_id.split('@').next() {
                    wallet.burn_auth_token_eagerly(cm_hex, block_ts);
                }
            }
        }

        // Step 3: Call add_notes() on all note ciphertexts.
        // - Receiver decryption: finds the leaves we just inserted → adds change notes to
        //   unspent_notes with correct tree_idx (so they can be spent later with valid nullifiers)
        // - Sender decryption: adds to outgoing_notes for TX history display
        if !all_note_cts.is_empty() {
            wallet.add_notes(&all_note_cts, 0, block_ts);
        }

        // Step 4: Also store unpublished notes for redundancy.
        // digest_block retries these on every block — if anything was missed, it gets picked up.
        wallet.add_unpublished_notes(&meta.unpublished_notes);
    }
    // ---- End eager wallet update ----

    // Convert Transaction to TransactionPacked with hex_data for each action
    let tx_packed = match transaction_to_packed(&tx) {
        Ok(p) => p,
        Err(e) => {
            set_last_error(&format!("wallet_transact_packed: failed to pack transaction: {e}"));
            return false;
        }
    };

    // Return tuple [TransactionPacked, meta] like wallet_transact
    let result = (tx_packed, meta);
    let json = match serde_json::to_string(&result) {
        Ok(j) => j,
        Err(e) => {
            set_last_error(&format!(
                "wallet_transact_packed: failed to serialize transaction: {e}"
            ));
            return false;
        }
    };

    match CString::new(json) {
        Ok(c_string) => {
            *out_tx_json = c_string.into_raw(); // caller must free with free_string
            true
        }
        Err(_) => {
            set_last_error(
                "wallet_transact_packed: CString::new failed (unexpected null byte in JSON)",
            );
            *out_tx_json = std::ptr::null();
            false
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_digest_block(
    p_wallet: *mut Wallet,
    block: *const libc::c_char,
    out_digest: &mut u64,
) -> bool {
    *out_digest = 0;

    if p_wallet.is_null() {
        set_last_error("wallet_digest_block: p_wallet is null");
        return false;
    }
    if block.is_null() {
        set_last_error("wallet_digest_block: block is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    let block_str: &str = match unsafe { CStr::from_ptr(block) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("wallet_digest_block: invalid UTF-8 in block");
            return false;
        }
    };

    *out_digest = wallet.digest_block(block_str);
    true
}

/// Derive a deterministic vault seed at the given index.
/// Writes the 32-byte seed as a 64-char hex string to out_hex.
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_derive_vault_seed(
    p_wallet: *mut Wallet,
    index: u32,
    out_hex: &mut *const libc::c_char,
) -> bool {
    *out_hex = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_derive_vault_seed: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &*p_wallet };
    if wallet.is_ivk() {
        set_last_error("wallet_derive_vault_seed: IVK wallet has no seed");
        return false;
    }

    let seed_bytes = wallet.derive_vault_seed(index);
    let hex_str = hex::encode(&seed_bytes);

    match CString::new(hex_str) {
        Ok(c_string) => {
            *out_hex = c_string.into_raw();
            true
        }
        Err(_) => {
            set_last_error("wallet_derive_vault_seed: CString::new failed");
            *out_hex = std::ptr::null();
            false
        }
    }
}

/// Compare spending keys of two wallets. Returns true if they derive from the same seed.
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_seeds_match(
    p_wallet_a: *mut Wallet,
    p_wallet_b: *mut Wallet,
) -> bool {
    if p_wallet_a.is_null() || p_wallet_b.is_null() {
        return false;
    }

    let wallet_a = unsafe { &*p_wallet_a };
    let wallet_b = unsafe { &*p_wallet_b };

    wallet_a.seed() == wallet_b.seed()
}

/// Create a deterministic vault: derives seed at vault_index, creates auth token
/// using the wallet's default address and the given contract. Returns JSON with
/// commitment hash and unpublished notes (same format as wallet_create_unpublished_auth_note).
#[cfg(any(target_os = "linux", target_os = "windows", target_os = "macos", target_os = "android"))]
#[no_mangle]
pub extern "C" fn wallet_create_deterministic_vault(
    p_wallet: *mut Wallet,
    contract: u64,
    vault_index: u32,
    out_json: &mut *const libc::c_char,
) -> bool {
    *out_json = std::ptr::null();

    if p_wallet.is_null() {
        set_last_error("wallet_create_deterministic_vault: p_wallet is null");
        return false;
    }

    let wallet = unsafe { &mut *p_wallet };
    if wallet.is_ivk() {
        set_last_error("wallet_create_deterministic_vault: IVK wallet has no seed");
        return false;
    }

    // derive the deterministic seed for this vault index
    let vault_seed_bytes = wallet.derive_vault_seed(vault_index);
    let vault_seed_hex = hex::encode(&vault_seed_bytes);

    // get the default address
    let addr = match wallet.default_address() {
        Some(a) => a,
        None => {
            set_last_error("wallet_create_deterministic_vault: no default address");
            return false;
        }
    };

    // create the auth token using the existing create_auth_token function
    let unpublished_notes_map = match create_auth_token(
        wallet,
        vault_seed_hex,
        Name(contract),
        addr,
    ) {
        Ok(m) => m,
        Err(e) => {
            set_last_error(&format!(
                "wallet_create_deterministic_vault: create_auth_token failed: {e:?}"
            ));
            return false;
        }
    };

    let json = match serde_json::to_string(&unpublished_notes_map) {
        Ok(j) => j,
        Err(e) => {
            set_last_error(&format!(
                "wallet_create_deterministic_vault: serialization failed: {e}"
            ));
            return false;
        }
    };

    match CString::new(json) {
        Ok(c_string) => {
            *out_json = c_string.into_raw();
            true
        }
        Err(_) => {
            set_last_error(
                "wallet_create_deterministic_vault: CString::new failed (unexpected null byte)",
            );
            *out_json = std::ptr::null();
            false
        }
    }
}

#[cfg(test)]
mod tests
{
    //#[test]
    //fn test_something()
    //{
    //}
}