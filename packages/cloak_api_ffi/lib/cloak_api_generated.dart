// CLOAK API FFI Bindings for libzeos_caterpillar
// Manually written (no ffigen - zeos-caterpillar has no .h file)

import 'dart:ffi' as ffi;

class NativeLibrary {
  final ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName) _lookup;

  NativeLibrary(ffi.DynamicLibrary dynamicLibrary) : _lookup = dynamicLibrary.lookup;

  // ============== Memory Management ==============

  void free_string(ffi.Pointer<ffi.Char> ptr) {
    return _free_string(ptr);
  }
  late final _free_stringPtr = _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Char>)>>('free_string');
  late final _free_string = _free_stringPtr.asFunction<void Function(ffi.Pointer<ffi.Char>)>();

  ffi.Pointer<ffi.Char> wallet_last_error() {
    return _wallet_last_error();
  }
  late final _wallet_last_errorPtr = _lookup<ffi.NativeFunction<ffi.Pointer<ffi.Char> Function()>>('wallet_last_error');
  late final _wallet_last_error = _wallet_last_errorPtr.asFunction<ffi.Pointer<ffi.Char> Function()>();

  // ============== Wallet Lifecycle ==============

  bool wallet_create(
    ffi.Pointer<ffi.Char> seed,
    bool is_ivk,
    ffi.Pointer<ffi.Char> chain_id,
    ffi.Pointer<ffi.Char> protocol_contract,
    ffi.Pointer<ffi.Char> vault_contract,
    ffi.Pointer<ffi.Char> alias_authority,
    ffi.Pointer<ffi.Pointer<ffi.Void>> out_wallet,
  ) {
    return _wallet_create(seed, is_ivk ? 1 : 0, chain_id, protocol_contract, vault_contract, alias_authority, out_wallet) != 0;
  }
  late final _wallet_createPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(
      ffi.Pointer<ffi.Char>,
      ffi.Uint8,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Pointer<ffi.Void>>,
    )
  >>('wallet_create');
  late final _wallet_create = _wallet_createPtr.asFunction<
    int Function(
      ffi.Pointer<ffi.Char>,
      int,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Pointer<ffi.Void>>,
    )
  >();

  void wallet_close(ffi.Pointer<ffi.Void> wallet) {
    return _wallet_close(wallet);
  }
  late final _wallet_closePtr = _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>('wallet_close');
  late final _wallet_close = _wallet_closePtr.asFunction<void Function(ffi.Pointer<ffi.Void>)>();

  bool wallet_size(ffi.Pointer<ffi.Void> wallet, ffi.Pointer<ffi.Uint64> out_size) {
    return _wallet_size(wallet, out_size) != 0;
  }
  late final _wallet_sizePtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint64>)
  >>('wallet_size');
  late final _wallet_size = _wallet_sizePtr.asFunction<int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint64>)>();

  bool wallet_write(ffi.Pointer<ffi.Void> wallet, ffi.Pointer<ffi.Uint8> out_bytes) {
    return _wallet_write(wallet, out_bytes) != 0;
  }
  late final _wallet_writePtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>)
  >>('wallet_write');
  late final _wallet_write = _wallet_writePtr.asFunction<int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>)>();

  bool wallet_read(
    ffi.Pointer<ffi.Uint8> bytes,
    int len,
    ffi.Pointer<ffi.Pointer<ffi.Void>> out_wallet,
  ) {
    return _wallet_read(bytes, len, out_wallet) != 0;
  }
  late final _wallet_readPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Uint8>, ffi.Size, ffi.Pointer<ffi.Pointer<ffi.Void>>)
  >>('wallet_read');
  late final _wallet_read = _wallet_readPtr.asFunction<
    int Function(ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Pointer<ffi.Void>>)
  >();

  // ============== Wallet Properties ==============

  bool wallet_seed_hex(ffi.Pointer<ffi.Void> wallet, ffi.Pointer<ffi.Pointer<ffi.Char>> out_seed) {
    return _wallet_seed_hex(wallet, out_seed) != 0;
  }
  late final _wallet_seed_hexPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_seed_hex');
  late final _wallet_seed_hex = _wallet_seed_hexPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  /// Get the Incoming Viewing Key as bech32m encoded string (ivk1...)
  bool wallet_ivk_bech32m(ffi.Pointer<ffi.Void> wallet, ffi.Pointer<ffi.Pointer<ffi.Char>> out_ivk) {
    return _wallet_ivk_bech32m(wallet, out_ivk) != 0;
  }
  late final _wallet_ivk_bech32mPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_ivk_bech32m');
  late final _wallet_ivk_bech32m = _wallet_ivk_bech32mPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  /// Get the Full Viewing Key as bech32m encoded string (fvk1...)
  bool wallet_fvk_bech32m(ffi.Pointer<ffi.Void> wallet, ffi.Pointer<ffi.Pointer<ffi.Char>> out_fvk) {
    return _wallet_fvk_bech32m(wallet, out_fvk) != 0;
  }
  late final _wallet_fvk_bech32mPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_fvk_bech32m');
  late final _wallet_fvk_bech32m = _wallet_fvk_bech32mPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  /// Get the Outgoing Viewing Key as bech32m encoded string (ovk1...)
  bool wallet_ovk_bech32m(ffi.Pointer<ffi.Void> wallet, ffi.Pointer<ffi.Pointer<ffi.Char>> out_ovk) {
    return _wallet_ovk_bech32m(wallet, out_ovk) != 0;
  }
  late final _wallet_ovk_bech32mPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_ovk_bech32m');
  late final _wallet_ovk_bech32m = _wallet_ovk_bech32mPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  bool wallet_is_ivk(ffi.Pointer<ffi.Void> wallet, ffi.Pointer<ffi.Uint8> out_is_ivk) {
    return _wallet_is_ivk(wallet, out_is_ivk) != 0;
  }
  late final _wallet_is_ivkPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>)
  >>('wallet_is_ivk');
  late final _wallet_is_ivk = _wallet_is_ivkPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>)
  >();

  bool wallet_chain_id(ffi.Pointer<ffi.Void> wallet, ffi.Pointer<ffi.Pointer<ffi.Char>> out_chain_id) {
    return _wallet_chain_id(wallet, out_chain_id) != 0;
  }
  late final _wallet_chain_idPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_chain_id');
  late final _wallet_chain_id = _wallet_chain_idPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  bool wallet_protocol_contract(ffi.Pointer<ffi.Void> wallet, ffi.Pointer<ffi.Pointer<ffi.Char>> out_contract) {
    return _wallet_protocol_contract(wallet, out_contract) != 0;
  }
  late final _wallet_protocol_contractPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_protocol_contract');
  late final _wallet_protocol_contract = _wallet_protocol_contractPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  bool wallet_vault_contract(ffi.Pointer<ffi.Void> wallet, ffi.Pointer<ffi.Pointer<ffi.Char>> out_contract) {
    return _wallet_vault_contract(wallet, out_contract) != 0;
  }
  late final _wallet_vault_contractPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_vault_contract');
  late final _wallet_vault_contract = _wallet_vault_contractPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  bool wallet_alias_authority(ffi.Pointer<ffi.Void> wallet, ffi.Pointer<ffi.Pointer<ffi.Char>> out_auth) {
    return _wallet_alias_authority(wallet, out_auth) != 0;
  }
  late final _wallet_alias_authorityPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_alias_authority');
  late final _wallet_alias_authority = _wallet_alias_authorityPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  bool wallet_block_num(ffi.Pointer<ffi.Void> wallet, ffi.Pointer<ffi.Uint32> out_num) {
    return _wallet_block_num(wallet, out_num) != 0;
  }
  late final _wallet_block_numPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>)
  >>('wallet_block_num');
  late final _wallet_block_num = _wallet_block_numPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>)
  >();

  bool wallet_leaf_count(ffi.Pointer<ffi.Void> wallet, ffi.Pointer<ffi.Uint64> out_count) {
    return _wallet_leaf_count(wallet, out_count) != 0;
  }
  late final _wallet_leaf_countPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint64>)
  >>('wallet_leaf_count');
  late final _wallet_leaf_count = _wallet_leaf_countPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint64>)
  >();

  bool wallet_auth_count(ffi.Pointer<ffi.Void> wallet, ffi.Pointer<ffi.Uint64> out_count) {
    return _wallet_auth_count(wallet, out_count) != 0;
  }
  late final _wallet_auth_countPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint64>)
  >>('wallet_auth_count');
  late final _wallet_auth_count = _wallet_auth_countPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint64>)
  >();

  bool wallet_set_auth_count(ffi.Pointer<ffi.Void> wallet, int count) {
    return _wallet_set_auth_count(wallet, count) != 0;
  }
  late final _wallet_set_auth_countPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Uint64)
  >>('wallet_set_auth_count');
  late final _wallet_set_auth_count = _wallet_set_auth_countPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, int)
  >();

  bool wallet_reset_chain_state(ffi.Pointer<ffi.Void> wallet) {
    return _wallet_reset_chain_state(wallet) != 0;
  }
  late final _wallet_reset_chain_statePtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>)
  >>('wallet_reset_chain_state');
  late final _wallet_reset_chain_state = _wallet_reset_chain_statePtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>)
  >();

  bool wallet_clear_unpublished_notes(ffi.Pointer<ffi.Void> wallet) {
    return _wallet_clear_unpublished_notes(wallet) != 0;
  }
  late final _wallet_clear_unpublished_notesPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>)
  >>('wallet_clear_unpublished_notes');
  late final _wallet_clear_unpublished_notes = _wallet_clear_unpublished_notesPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>)
  >();

  // ============== Address ==============

  bool wallet_default_address(
    ffi.Pointer<ffi.Void> wallet,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_address,
  ) {
    return _wallet_default_address(wallet, out_address) != 0;
  }
  late final _wallet_default_addressPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_default_address');
  late final _wallet_default_address = _wallet_default_addressPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  bool wallet_derive_address(
    ffi.Pointer<ffi.Void> wallet,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_address,
  ) {
    return _wallet_derive_address(wallet, out_address) != 0;
  }
  late final _wallet_derive_addressPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_derive_address');
  late final _wallet_derive_address = _wallet_derive_addressPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  bool wallet_addresses_json(
    ffi.Pointer<ffi.Void> wallet,
    bool pretty,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_json,
  ) {
    return _wallet_addresses_json(wallet, pretty ? 1 : 0, out_json) != 0;
  }
  late final _wallet_addresses_jsonPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Uint8, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_addresses_json');
  late final _wallet_addresses_json = _wallet_addresses_jsonPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  // ============== Balance/Notes ==============

  bool wallet_balances_json(
    ffi.Pointer<ffi.Void> wallet,
    bool pretty,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_json,
  ) {
    return _wallet_balances_json(wallet, pretty ? 1 : 0, out_json) != 0;
  }
  late final _wallet_balances_jsonPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Uint8, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_balances_json');
  late final _wallet_balances_json = _wallet_balances_jsonPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  bool wallet_estimate_send_fee(
    ffi.Pointer<ffi.Void> wallet,
    int sendAmount,
    ffi.Pointer<ffi.Char> feesJson,
    ffi.Pointer<ffi.Char> feeTokenContract,
    ffi.Pointer<ffi.Char> recipientAddr,
    ffi.Pointer<ffi.Uint64> outFee,
  ) {
    return _wallet_estimate_send_fee(wallet, sendAmount, feesJson, feeTokenContract, recipientAddr, outFee) != 0;
  }
  late final _wallet_estimate_send_feePtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Uint64, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint64>)
  >>('wallet_estimate_send_fee');
  late final _wallet_estimate_send_fee = _wallet_estimate_send_feePtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint64>)
  >();

  bool wallet_estimate_burn_fee(
    ffi.Pointer<ffi.Void> wallet,
    bool hasAssets,
    ffi.Pointer<ffi.Char> feesJson,
    ffi.Pointer<ffi.Char> feeTokenContract,
    ffi.Pointer<ffi.Uint64> outFee,
  ) {
    return _wallet_estimate_burn_fee(wallet, hasAssets ? 1 : 0, feesJson, feeTokenContract, outFee) != 0;
  }
  late final _wallet_estimate_burn_feePtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Uint8, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint64>)
  >>('wallet_estimate_burn_fee');
  late final _wallet_estimate_burn_fee = _wallet_estimate_burn_feePtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint64>)
  >();

  bool wallet_estimate_vault_creation_fee(
    ffi.Pointer<ffi.Void> wallet,
    ffi.Pointer<ffi.Char> feesJson,
    ffi.Pointer<ffi.Char> feeTokenContract,
    ffi.Pointer<ffi.Uint64> outFee,
  ) {
    return _wallet_estimate_vault_creation_fee(wallet, feesJson, feeTokenContract, outFee) != 0;
  }
  late final _wallet_estimate_vault_creation_feePtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint64>)
  >>('wallet_estimate_vault_creation_fee');
  late final _wallet_estimate_vault_creation_fee = _wallet_estimate_vault_creation_feePtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint64>)
  >();

  bool wallet_unspent_notes_json(
    ffi.Pointer<ffi.Void> wallet,
    bool pretty,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_json,
  ) {
    return _wallet_unspent_notes_json(wallet, pretty ? 1 : 0, out_json) != 0;
  }
  late final _wallet_unspent_notes_jsonPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Uint8, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_unspent_notes_json');
  late final _wallet_unspent_notes_json = _wallet_unspent_notes_jsonPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  bool wallet_fungible_tokens_json(
    ffi.Pointer<ffi.Void> wallet,
    int symbol,
    int contract,
    bool pretty,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_json,
  ) {
    return _wallet_fungible_tokens_json(wallet, symbol, contract, pretty ? 1 : 0, out_json) != 0;
  }
  late final _wallet_fungible_tokens_jsonPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Uint64, ffi.Uint64, ffi.Uint8, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_fungible_tokens_json');
  late final _wallet_fungible_tokens_json = _wallet_fungible_tokens_jsonPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, int, int, int, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  bool wallet_non_fungible_tokens_json(
    ffi.Pointer<ffi.Void> wallet,
    int contract,
    bool pretty,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_json,
  ) {
    return _wallet_non_fungible_tokens_json(wallet, contract, pretty ? 1 : 0, out_json) != 0;
  }
  late final _wallet_non_fungible_tokens_jsonPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Uint64, ffi.Uint8, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_non_fungible_tokens_json');
  late final _wallet_non_fungible_tokens_json = _wallet_non_fungible_tokens_jsonPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, int, int, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  bool wallet_transaction_history_json(
    ffi.Pointer<ffi.Void> wallet,
    bool pretty,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_json,
  ) {
    return _wallet_transaction_history_json(wallet, pretty ? 1 : 0, out_json) != 0;
  }
  late final _wallet_transaction_history_jsonPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Uint8, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_transaction_history_json');
  late final _wallet_transaction_history_json = _wallet_transaction_history_jsonPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  bool wallet_json(
    ffi.Pointer<ffi.Void> wallet,
    bool pretty,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_json,
  ) {
    return _wallet_json(wallet, pretty ? 1 : 0, out_json) != 0;
  }
  late final _wallet_jsonPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Uint8, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_json');
  late final _wallet_json = _wallet_jsonPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  // ============== Block Sync ==============

  bool wallet_digest_block(
    ffi.Pointer<ffi.Void> wallet,
    ffi.Pointer<ffi.Char> block_json,
    ffi.Pointer<ffi.Uint64> out_digest,
  ) {
    return _wallet_digest_block(wallet, block_json, out_digest) != 0;
  }
  late final _wallet_digest_blockPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint64>)
  >>('wallet_digest_block');
  late final _wallet_digest_block = _wallet_digest_blockPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint64>)
  >();

  // ============== Merkle Tree / Notes ==============

  /// Add merkle tree leaves (hex-encoded concatenated 32-byte values)
  bool wallet_add_leaves(
    ffi.Pointer<ffi.Void> wallet,
    ffi.Pointer<ffi.Char> leaves_hex,
  ) {
    return _wallet_add_leaves(wallet, leaves_hex) != 0;
  }
  late final _wallet_add_leavesPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>)
  >>('wallet_add_leaves');
  late final _wallet_add_leaves = _wallet_add_leavesPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>)
  >();

  /// Mark notes as spent by providing on-chain nullifiers (hex-encoded concatenated 32-byte values)
  /// Returns the number of notes marked as spent via out_count
  bool wallet_add_nullifiers(
    ffi.Pointer<ffi.Void> wallet,
    ffi.Pointer<ffi.Char> nullifiers_hex,
    ffi.Pointer<ffi.Uint64> out_count,
  ) {
    return _wallet_add_nullifiers(wallet, nullifiers_hex, out_count) != 0;
  }
  late final _wallet_add_nullifiersPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint64>)
  >>('wallet_add_nullifiers');
  late final _wallet_add_nullifiers = _wallet_add_nullifiersPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Uint64>)
  >();

  /// Add encrypted notes for trial decryption (JSON array of base64 strings)
  /// block_num and block_ts provide timestamps for the notes (used in transaction history)
  /// Returns packed count: (ats << 16) | (nfts << 8) | fts, or 0 on error
  int wallet_add_notes(
    ffi.Pointer<ffi.Void> wallet,
    ffi.Pointer<ffi.Char> notes_json,
    int block_num,
    int block_ts,
  ) {
    return _wallet_add_notes(wallet, notes_json, block_num, block_ts);
  }
  late final _wallet_add_notesPtr = _lookup<ffi.NativeFunction<
    ffi.Uint64 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>, ffi.Uint32, ffi.Uint64)
  >>('wallet_add_notes');
  late final _wallet_add_notes = _wallet_add_notesPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>, int, int)
  >();

  // ============== Transactions ==============

  /// Build and sign a ZEOS transaction
  /// Returns signed EOSIO transaction JSON ready for broadcast
  bool wallet_transact(
    ffi.Pointer<ffi.Void> wallet,
    ffi.Pointer<ffi.Char> ztx_json,
    ffi.Pointer<ffi.Char> fee_token_contract_json,
    ffi.Pointer<ffi.Char> fees_json,
    ffi.Pointer<ffi.Uint8> mint_params,
    int mint_params_len,
    ffi.Pointer<ffi.Uint8> spendoutput_params,
    int spendoutput_params_len,
    ffi.Pointer<ffi.Uint8> spend_params,
    int spend_params_len,
    ffi.Pointer<ffi.Uint8> output_params,
    int output_params_len,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_tx_json,
  ) {
    return _wallet_transact(
      wallet,
      ztx_json,
      fee_token_contract_json,
      fees_json,
      mint_params,
      mint_params_len,
      spendoutput_params,
      spendoutput_params_len,
      spend_params,
      spend_params_len,
      output_params,
      output_params_len,
      out_tx_json,
    ) != 0;
  }
  late final _wallet_transactPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    )
  >>('wallet_transact');
  late final _wallet_transact = _wallet_transactPtr.asFunction<
    int Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    )
  >();

  /// Like wallet_transact but returns actions with hex_data for ABI-serialized binary data.
  /// This is needed for ESR/Anchor wallet which expects ABI-encoded action data.
  bool wallet_transact_packed(
    ffi.Pointer<ffi.Void> wallet,
    ffi.Pointer<ffi.Char> ztx_json,
    ffi.Pointer<ffi.Char> fee_token_contract_json,
    ffi.Pointer<ffi.Char> fees_json,
    ffi.Pointer<ffi.Uint8> mint_params,
    int mint_params_len,
    ffi.Pointer<ffi.Uint8> spendoutput_params,
    int spendoutput_params_len,
    ffi.Pointer<ffi.Uint8> spend_params,
    int spend_params_len,
    ffi.Pointer<ffi.Uint8> output_params,
    int output_params_len,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_tx_json,
  ) {
    return _wallet_transact_packed(
      wallet,
      ztx_json,
      fee_token_contract_json,
      fees_json,
      mint_params,
      mint_params_len,
      spendoutput_params,
      spendoutput_params_len,
      spend_params,
      spend_params_len,
      output_params,
      output_params_len,
      out_tx_json,
    ) != 0;
  }
  late final _wallet_transact_packedPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    )
  >>('wallet_transact_packed');
  late final _wallet_transact_packed = _wallet_transact_packedPtr.asFunction<
    int Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    )
  >();

  // ============== Vault / Auth Tokens ==============

  /// Get authentication tokens (vaults) as JSON
  /// contract: EOSIO name as u64 (0 for all)
  /// spent: if true, include spent tokens
  /// seed: if true, include seed/memo in output format "<hash>@<contract>|<seed>"
  bool wallet_authentication_tokens_json(
    ffi.Pointer<ffi.Void> wallet,
    int contract,
    bool spent,
    bool seed,
    bool pretty,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_json,
  ) {
    return _wallet_authentication_tokens_json(wallet, contract, spent ? 1 : 0, seed ? 1 : 0, pretty ? 1 : 0, out_json) != 0;
  }
  late final _wallet_authentication_tokens_jsonPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Uint64, ffi.Uint8, ffi.Uint8, ffi.Uint8, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_authentication_tokens_json');
  late final _wallet_authentication_tokens_json = _wallet_authentication_tokens_jsonPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, int, int, int, int, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  /// Get unpublished notes as JSON (notes created but not yet on-chain)
  bool wallet_unpublished_notes_json(
    ffi.Pointer<ffi.Void> wallet,
    bool pretty,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_json,
  ) {
    return _wallet_unpublished_notes_json(wallet, pretty ? 1 : 0, out_json) != 0;
  }
  late final _wallet_unpublished_notes_jsonPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Uint8, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_unpublished_notes_json');
  late final _wallet_unpublished_notes_json = _wallet_unpublished_notes_jsonPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  /// Add unpublished notes to wallet (JSON map: address -> [note_ct_base64, ...])
  bool wallet_add_unpublished_notes(
    ffi.Pointer<ffi.Void> wallet,
    ffi.Pointer<ffi.Char> unpublished_notes_json,
  ) {
    return _wallet_add_unpublished_notes(wallet, unpublished_notes_json) != 0;
  }
  late final _wallet_add_unpublished_notesPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>)
  >>('wallet_add_unpublished_notes');
  late final _wallet_add_unpublished_notes = _wallet_add_unpublished_notesPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>)
  >();

  /// Create an unpublished auth note (vault) for receiving tokens
  /// seed: random seed string for note
  /// contract: token contract name as u64
  /// address: recipient bech32m address
  /// Returns JSON map of unpublished notes
  bool wallet_create_unpublished_auth_note(
    ffi.Pointer<ffi.Void> wallet,
    ffi.Pointer<ffi.Char> seed,
    int contract,
    ffi.Pointer<ffi.Char> address,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_unpublished_notes,
  ) {
    return _wallet_create_unpublished_auth_note(wallet, seed, contract, address, out_unpublished_notes) != 0;
  }
  late final _wallet_create_unpublished_auth_notePtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>, ffi.Uint64, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_create_unpublished_auth_note');
  late final _wallet_create_unpublished_auth_note = _wallet_create_unpublished_auth_notePtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>, int, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  // ============== Deterministic Vault Functions ==============

  /// Derive a deterministic vault seed at the given index.
  /// Returns hex-encoded 32-byte HMAC-SHA256 seed via out_hex.
  bool wallet_derive_vault_seed(
    ffi.Pointer<ffi.Void> wallet,
    int index,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_hex,
  ) {
    return _wallet_derive_vault_seed(wallet, index, out_hex) != 0;
  }
  late final _wallet_derive_vault_seedPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_derive_vault_seed');
  late final _wallet_derive_vault_seed = _wallet_derive_vault_seedPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();

  /// Compare spending keys of two wallets. Returns true if they derive from the same seed.
  bool wallet_seeds_match(
    ffi.Pointer<ffi.Void> wallet_a,
    ffi.Pointer<ffi.Void> wallet_b,
  ) {
    return _wallet_seeds_match(wallet_a, wallet_b) != 0;
  }
  late final _wallet_seeds_matchPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
  >>('wallet_seeds_match');
  late final _wallet_seeds_match = _wallet_seeds_matchPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
  >();

  /// Create a deterministic vault: derives seed at vault_index, creates auth token
  /// using the wallet's default address and the given contract.
  /// Returns JSON with commitment hash and unpublished notes.
  bool wallet_create_deterministic_vault(
    ffi.Pointer<ffi.Void> wallet,
    int contract,
    int vault_index,
    ffi.Pointer<ffi.Pointer<ffi.Char>> out_json,
  ) {
    return _wallet_create_deterministic_vault(wallet, contract, vault_index, out_json) != 0;
  }
  late final _wallet_create_deterministic_vaultPtr = _lookup<ffi.NativeFunction<
    ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Uint64, ffi.Uint32, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >>('wallet_create_deterministic_vault');
  late final _wallet_create_deterministic_vault = _wallet_create_deterministic_vaultPtr.asFunction<
    int Function(ffi.Pointer<ffi.Void>, int, int, ffi.Pointer<ffi.Pointer<ffi.Char>>)
  >();
}
