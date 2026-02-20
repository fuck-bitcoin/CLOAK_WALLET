import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';
import '../../utils/photo_encoder.dart';
import '../../utils/photo_models.dart';
import '../../utils/transaction_size_verifier.dart';
import '../../accounts.dart';
import '../../appsettings.dart';
import '../../store2.dart';
import '../utils.dart';
import '../widgets.dart';
import '../../generated/intl/messages.dart';

class PhotoSendContext {
  final String address;
  final List<PhotoChunk> chunks;
  final String cid;
  final int seq;
  final String displayName;
  final int? threadIndex;
  
  PhotoSendContext({
    required this.address,
    required this.chunks,
    required this.cid,
    required this.seq,
    required this.displayName,
    this.threadIndex,
  });
}

class SendPhotoPage extends StatefulWidget {
  final PhotoSendContext? photoContext;
  
  SendPhotoPage({this.photoContext});
  
  @override
  State<StatefulWidget> createState() => _SendPhotoState();
}

class _SendPhotoState extends State<SendPhotoPage> {
  bool _sending = false;
  int _currentTxIndex = 0;
  int _totalTxCount = 0;
  SendingOverlayController? _sendingOverlay;
  
  @override
  void initState() {
    super.initState();
    final ctx = widget.photoContext;
    if (ctx != null) {
      // Calculate number of batches needed
      _totalTxCount = (ctx.chunks.length / PhotoEncoder.MAX_CHUNKS_PER_TX).ceil();
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final ctx = widget.photoContext;
    if (ctx == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        GoRouter.of(context).pop();
      });
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.maybePop(context),
          ),
          title: Text('Send Photo'),
        ),
        body: Center(child: Text('No photo context')),
      );
    }
    
    // Group chunks into batches (MAX_CHUNKS_PER_TX)
    final batches = <List<PhotoChunk>>[];
    for (int i = 0; i < ctx.chunks.length; i += PhotoEncoder.MAX_CHUNKS_PER_TX) {
      final end = (i + PhotoEncoder.MAX_CHUNKS_PER_TX).clamp(0, ctx.chunks.length);
      batches.add(ctx.chunks.sublist(i, end));
    }
    
    // Verify transaction sizes
    final sizeVerifications = TransactionSizeVerifier.verifyAllBatches(ctx.chunks);
    final hasWarnings = sizeVerifications.any((v) => !v['isAcceptable'] as bool);
    
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text('Send Photo'),
      ),
      body: Column(
        children: [
          // Photo preview
          Container(
            padding: EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  'Photo: ${ctx.chunks.length} chunks',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                SizedBox(height: 8),
                Text(
                  '${batches.length} transaction(s) required',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (hasWarnings)
                  Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Container(
                      padding: EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning, size: 16, color: Colors.orange),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Some transactions may be too large. Consider reducing batch size.',
                              style: TextStyle(fontSize: 12, color: Colors.orange[800]),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          
          // Transaction size details (expandable)
          if (batches.length > 1)
            ExpansionTile(
              title: Text('Transaction Details'),
              children: sizeVerifications.map((v) {
                return ListTile(
                  dense: true,
                  title: Text('Batch ${v['batchIndex']}: ${v['chunkCount']} chunks'),
                  subtitle: Text(
                    'Estimated size: ${((v['estimatedSize'] as int) / 1024).toStringAsFixed(1)} KB',
                  ),
                  trailing: v['isAcceptable'] as bool
                      ? Icon(Icons.check_circle, color: Colors.green, size: 20)
                      : Icon(Icons.warning, color: Colors.orange, size: 20),
                );
              }).toList(),
            ),
          
          // Progress indicator
          if (_sending)
            Container(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  LinearProgressIndicator(
                    value: _totalTxCount > 0 ? _currentTxIndex / _totalTxCount : 0.0,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Sending transaction $_currentTxIndex of $_totalTxCount',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          
          Expanded(child: SizedBox()),
          
          // Send button
          Container(
            padding: EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _sending ? null : () => _sendPhoto(ctx, batches),
                child: Text(_sending ? 'Sending...' : 'Send Photo'),
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Future<void> _sendPhoto(PhotoSendContext ctx, List<List<PhotoChunk>> batches) async {
    setState(() {
      _sending = true;
      _currentTxIndex = 0;
    });
    
    // Show sending overlay
    _sendingOverlay ??= SendingOverlayController();
    try {
      _sendingOverlay!.show(context);
    } catch (_) {}
    
    // Pause sync during sending
    try { syncStatus2.setPause(true); } catch (_) {}
    
    // Initialize prover before signing (lazy initialization)
    try {
      final spend = await rootBundle.load('assets/sapling-spend.params');
      final output = await rootBundle.load('assets/sapling-output.params');
      WarpApi.initProver(spend.buffer.asUint8List(), output.buffer.asUint8List());
      appStore.proverReady = true;
    } catch (_) {}
    
    try {
      for (int i = 0; i < batches.length; i++) {
        setState(() => _currentTxIndex = i + 1);
        
        final batch = batches[i];
        final batchNumber = i + 1;
        final totalBatches = batches.length;
        
        // Build recipients
        final recipients = batch.map((chunk) {
          final memoBody = PhotoEncoder.buildChunkMemo(chunk);
          final builder = RecipientObjectBuilder(
            address: ctx.address,
            pools: 4, // Orchard only
            amount: 0, // zero-value memo-only transaction
            feeIncluded: false,
            replyTo: false,
            subject: '',
            memo: memoBody,
          );
          return Recipient(builder.toBytes());
        }).toList();
        
        // Prepare transaction with error handling
        String txPlan;
        try {
          try { 
            _sendingOverlay?.setStatus('Preparing batch $batchNumber of $totalBatches…'); 
          } catch (_) {}
          
          txPlan = await WarpApi.prepareTx(
            aa.coin,
            aa.id,
            recipients,
            7, // pools
            coinSettings.replyUa,
            appSettings.anchorOffset,
            coinSettings.feeT,
          );
        } catch (e) {
          try { _sendingOverlay?.hide(); } catch (_) {}
          try { syncStatus2.setPause(false); } catch (_) {}
          await showMessageBox2(context, 'Error', 'Failed to prepare transaction ${i + 1}: $e');
          return;
        }
        
        // Sign transaction
        try { 
          _sendingOverlay?.setStatus('Signing batch $batchNumber of $totalBatches…'); 
        } catch (_) {}
        
        String signedTx;
        try {
          signedTx = await WarpApi.signOnly(aa.coin, aa.id, txPlan);
        } on String catch (e) {
          // Handle "Prover not initialized" error
          if (e.contains('Prover not initialized')) {
            try {
              final spend = await rootBundle.load('assets/sapling-spend.params');
              final output = await rootBundle.load('assets/sapling-output.params');
              WarpApi.initProver(spend.buffer.asUint8List(), output.buffer.asUint8List());
              appStore.proverReady = true;
              signedTx = await WarpApi.signOnly(aa.coin, aa.id, txPlan);
            } on String catch (e2) {
              try { _sendingOverlay?.hide(); } catch (_) {}
              try { syncStatus2.setPause(false); } catch (_) {}
              await showMessageBox2(context, 'Error', 'Failed to sign transaction ${i + 1}: $e2');
              return;
            }
          } else {
            try { _sendingOverlay?.hide(); } catch (_) {}
            try { syncStatus2.setPause(false); } catch (_) {}
            await showMessageBox2(context, 'Error', 'Failed to sign transaction ${i + 1}: $e');
            return;
          }
        } catch (e) {
          try { _sendingOverlay?.hide(); } catch (_) {}
          try { syncStatus2.setPause(false); } catch (_) {}
          await showMessageBox2(context, 'Error', 'Failed to sign transaction ${i + 1}: $e');
          return;
        }
        
        // Broadcast transaction
        try { 
          _sendingOverlay?.setStatus('Broadcasting batch $batchNumber of $totalBatches…'); 
        } catch (_) {}
        
        try {
          await WarpApi.broadcast(aa.coin, signedTx);
        } catch (e) {
          try { _sendingOverlay?.hide(); } catch (_) {}
          try { syncStatus2.setPause(false); } catch (_) {}
          await showMessageBox2(context, 'Error', 'Failed to broadcast transaction ${i + 1}: $e');
          return;
        }
        
        // Wait a moment before sending next batch
        if (i < batches.length - 1) {
          await Future.delayed(Duration(seconds: 1));
        }
      }
      
      // Show success message
      try { 
        _sendingOverlay?.setStatus('Photo sent successfully!'); 
      } catch (_) {}
      await Future.delayed(Duration(milliseconds: 500)); // Brief success message
      
      // Hide overlay and resume sync
      try { _sendingOverlay?.hide(); } catch (_) {}
      try { syncStatus2.setPause(false); } catch (_) {}
      
      // Return to messages
      GoRouter.of(context).pop();
      if (ctx.threadIndex != null) {
        GoRouter.of(context).push('/messages/details?index=${ctx.threadIndex}');
      }
    } catch (e) {
      try { _sendingOverlay?.hide(); } catch (_) {}
      try { syncStatus2.setPause(false); } catch (_) {}
      await showMessageBox2(context, 'Error', 'Failed to send photo: $e');
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }
}

