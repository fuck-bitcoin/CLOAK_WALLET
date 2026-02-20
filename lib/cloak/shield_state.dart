// Shield State Store (MobX)
// Manages state for shielding tokens from Telos to CLOAK

import 'package:mobx/mobx.dart';
import 'eosio_client.dart';

part 'shield_state.g.dart';

/// Global shield store instance
var shieldStore = ShieldStore();

class ShieldStore = _ShieldStore with _$ShieldStore;

abstract class _ShieldStore with Store {
  /// Telos account name (not persisted - cleared on navigate away)
  @observable
  String? telosAccountName;

  /// Available tokens for the account (from Hyperion)
  @observable
  ObservableList<TokenBalance> availableTokens = ObservableList();

  /// Currently selected token for shielding
  @observable
  TokenBalance? selectedToken;

  /// Amount to shield (user input as string)
  @observable
  String amount = '';

  /// Loading state for token fetch
  @observable
  bool isLoadingTokens = false;

  /// Loading state for shield operation
  @observable
  bool isShielding = false;

  /// Error message
  @observable
  String? error;

  /// Status message (for progress feedback)
  @observable
  String? statusMessage;

  /// Whether we have a valid account with tokens
  @computed
  bool get hasAccount => telosAccountName != null && telosAccountName!.isNotEmpty;

  /// Whether shield button should be enabled
  @computed
  bool get canShield =>
      hasAccount &&
      selectedToken != null &&
      amount.isNotEmpty &&
      !isShielding &&
      _isValidAmount;

  /// Validate amount is numeric and within balance
  bool get _isValidAmount {
    final numAmount = double.tryParse(amount);
    if (numAmount == null || numAmount <= 0) return false;
    if (selectedToken == null) return false;
    return numAmount <= selectedToken!.numericAmount;
  }

  /// Set the Telos account and fetch tokens
  @action
  Future<void> setAccount(String accountName) async {
    telosAccountName = accountName;
    selectedToken = null;
    amount = '';
    error = null;
    availableTokens.clear();
    isLoadingTokens = true; // Show loading immediately

    try {
      // Prefetch Telos token list for logo URLs (small JSON, not images)
      // This runs in parallel with token fetch for better performance
      await Future.wait([
        fetchTelosTokenList(),
        _fetchTokensInternal(),
      ]);
    } finally {
      isLoadingTokens = false;
    }
  }

  /// Internal token fetch (called from setAccount)
  Future<void> _fetchTokensInternal() async {
    if (telosAccountName == null || telosAccountName!.isEmpty) {
      return;
    }

    try {
      final tokens = await getAccountTokens(telosAccountName!);
      availableTokens.clear();
      availableTokens.addAll(tokens);

      if (tokens.isEmpty) {
        error = 'No tokens found for this account';
      }
    } catch (e) {
      error = 'Failed to fetch tokens: $e';
    }
  }

  /// Select a token for shielding
  @action
  void selectToken(TokenBalance token) {
    selectedToken = token;
    amount = ''; // Reset amount when changing token
    error = null;
  }

  /// Set amount to shield
  @action
  void setAmount(String value) {
    amount = value;
    error = null;
  }

  /// Set amount to MAX (full balance)
  @action
  void setMaxAmount() {
    if (selectedToken != null) {
      amount = selectedToken!.amount;
    }
  }

  /// Set error message
  @action
  void setError(String? message) {
    error = message;
  }

  /// Set status message
  @action
  void setStatus(String? message) {
    statusMessage = message;
  }

  /// Set shielding state
  @action
  void setShielding(bool value) {
    isShielding = value;
    if (!value) {
      statusMessage = null;
    }
  }

  /// Clear all state (called when navigating away)
  @action
  void clear() {
    telosAccountName = null;
    availableTokens.clear();
    selectedToken = null;
    amount = '';
    error = null;
    statusMessage = null;
    isShielding = false;
    isLoadingTokens = false;
  }
}
