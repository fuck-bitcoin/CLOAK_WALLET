import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../cloak/cloak_wallet_manager.dart';

/// Default path to the CLOAK GUI desktop wallet file.
const _defaultGuiWalletPath = '/opt/cloak-gui/wallet.bin';

/// Page to import a CLOAK GUI wallet.bin file.
/// Extracts auth tokens and unpublished notes from the GUI wallet
/// and injects them into the current Flutter wallet without affecting
/// balance, sync state, or transaction history.
class ImportGuiWalletPage extends StatefulWidget {
  const ImportGuiWalletPage({super.key});

  @override
  State<ImportGuiWalletPage> createState() => _ImportGuiWalletPageState();
}

class _ImportGuiWalletPageState extends State<ImportGuiWalletPage> {
  late final TextEditingController _pathController;
  bool _importing = false;
  String _status = '';
  final List<String> _log = [];

  @override
  void initState() {
    super.initState();
    // Pre-fill with default GUI wallet path if it exists
    _pathController = TextEditingController(
      text: File(_defaultGuiWalletPath).existsSync()
          ? _defaultGuiWalletPath
          : '',
    );
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Select CLOAK GUI wallet file',
        type: FileType.any,
      );
      if (result != null && result.files.single.path != null) {
        setState(() {
          _pathController.text = result.files.single.path!;
          _status = '';
          _log.clear();
        });
      }
    } catch (e) {
      // File picker can fail on some Linux configs — user can type path manually
      setState(() {
        _status = 'File picker failed: $e — enter path manually below';
      });
    }
  }

  String? get _selectedPath {
    final text = _pathController.text.trim();
    return text.isEmpty ? null : text;
  }

  void _addLog(String msg) {
    setState(() {
      _log.add(msg);
    });
  }

  Future<void> _doImport() async {
    final path = _selectedPath;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) {
      _addLog('File not found: $path');
      setState(() => _status = 'File not found');
      return;
    }

    setState(() {
      _importing = true;
      _status = 'Reading wallet file...';
      _log.clear();
    });

    try {
      final result = await CloakWalletManager.importFromGuiWalletFile(
        path,
        onLog: _addLog,
        onStatus: (s) => setState(() => _status = s),
      );

      setState(() {
        _importing = false;
        _status = result
            ? 'Import successful! Auth tokens synced.'
            : 'Import failed. Check log below.';
      });
    } catch (e) {
      setState(() {
        _importing = false;
        _status = 'Error: $e';
      });
      _addLog('Exception: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Import GUI Wallet')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Import auth tokens from a CLOAK GUI wallet file. '
              'This syncs vault auth tokens and unpublished notes '
              'without affecting your balance or transaction history.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),

            // Path text field with browse button
            TextField(
              controller: _pathController,
              enabled: !_importing,
              decoration: InputDecoration(
                labelText: 'Wallet file path',
                hintText: _defaultGuiWalletPath,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  onPressed: _importing ? null : _pickFile,
                  icon: const Icon(Icons.folder_open),
                  tooltip: 'Browse...',
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),

            // Import button
            ElevatedButton.icon(
              onPressed: (_selectedPath != null && !_importing)
                  ? _doImport
                  : null,
              icon: _importing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              label: Text(_importing ? 'Importing...' : 'Import'),
            ),

            // Status
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                _status,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _status.startsWith('Error') || _status.startsWith('Import failed')
                      ? theme.colorScheme.error
                      : _status.startsWith('Import successful')
                          ? Colors.green
                          : null,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],

            // Log output
            if (_log.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Divider(),
              Text('Log:', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView.builder(
                    itemCount: _log.length,
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        _log[i],
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ] else
              const Spacer(),
          ],
        ),
      ),
    );
  }
}
