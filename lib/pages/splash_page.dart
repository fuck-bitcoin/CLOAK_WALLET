import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../cloak/params_manager.dart';

/// First-launch page: checks for ZK params, downloads if missing,
/// then shows Create / Restore account buttons.
class CloakSplashPage extends StatefulWidget {
  const CloakSplashPage({super.key});

  @override
  State<CloakSplashPage> createState() => _CloakSplashPageState();
}

class _CloakSplashPageState extends State<CloakSplashPage> {
  static const _josefin = 'JosefinSans';

  // Params state
  bool _checkingParams = true;
  bool _paramsReady = false;
  bool _downloading = false;
  String _statusMessage = 'Checking ZK parameters...';
  String _currentFile = '';
  double _fileProgress = 0;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _checkParams();
  }

  Future<void> _checkParams() async {
    try {
      final dir = await ParamsManager.getParamsDirectory();
      final exist = await ParamsManager.paramsExist(dir);
      if (mounted) {
        setState(() {
          _checkingParams = false;
          _paramsReady = exist;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _checkingParams = false;
          _paramsReady = false;
          _errorMessage = 'Failed to check params: $e';
        });
      }
    }
  }

  Future<void> _downloadParams() async {
    setState(() {
      _downloading = true;
      _errorMessage = null;
      _statusMessage = 'Preparing download...';
      _fileProgress = 0;
      _currentFile = '';
    });

    try {
      final dir = await ParamsManager.getParamsDirectory();
      await ParamsManager.downloadParams(
        targetDir: dir,
        onFileProgress: (file, downloaded, total) {
          if (mounted) {
            setState(() {
              _currentFile = file;
              _fileProgress = total > 0 ? downloaded / total : 0;
            });
          }
        },
        onStatus: (message) {
          if (mounted) {
            setState(() => _statusMessage = message);
          }
        },
      );

      if (mounted) {
        setState(() {
          _downloading = false;
          _paramsReady = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _errorMessage = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: _checkingParams
                ? _buildChecking()
                : _paramsReady
                    ? _buildReady()
                    : _downloading
                        ? _buildDownloading()
                        : _buildNeedParams(),
          ),
        ),
      ),
    );
  }

  /// Checking if params exist (brief spinner on first load).
  Widget _buildChecking() {
    return Column(
      children: [
        const Spacer(flex: 3),
        _buildHeader(),
        const Spacer(flex: 3),
        const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(0xFF4CAF50),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          _statusMessage,
          style: TextStyle(
            color: Colors.white.withOpacity(0.5),
            fontSize: 13,
          ),
        ),
        const Spacer(flex: 2),
      ],
    );
  }

  /// Params are ready — show Create / Restore buttons.
  Widget _buildReady() {
    return Column(
      children: [
        const Spacer(flex: 3),
        const SizedBox(height: 28),
        _buildHeader(),
        const Spacer(flex: 4),
        // Create Account button (primary)
        SizedBox(
          width: double.infinity,
          height: 52,
          child: Material(
            color: const Color(0xFF4CAF50),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () =>
                  GoRouter.of(context).push('/splash/pin_setup?next=create'),
              child: const Center(
                child: Text(
                  'Create Account',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        // Restore Account button (secondary)
        SizedBox(
          width: double.infinity,
          height: 52,
          child: Material(
            color: const Color(0xFF2E2C2C),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () =>
                  GoRouter.of(context).push('/splash/pin_setup?next=restore'),
              child: Center(
                child: Text(
                  'Restore Account',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.8),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
        const Spacer(flex: 2),
      ],
    );
  }

  /// Params not found — show download prompt (or error with retry).
  Widget _buildNeedParams() {
    return Column(
      children: [
        const Spacer(flex: 3),
        _buildHeader(),
        const Spacer(flex: 2),
        Icon(
          Icons.cloud_download_outlined,
          color: Colors.white.withOpacity(0.6),
          size: 48,
        ),
        const SizedBox(height: 20),
        Text(
          'ZK Parameters Required',
          style: TextStyle(
            fontFamily: _josefin,
            fontWeight: FontWeight.w300,
            fontSize: 18,
            color: Colors.white.withOpacity(0.9),
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'CLOAK Wallet needs zero-knowledge proving parameters (~383 MB) '
          'to generate private transactions. This is a one-time download.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withOpacity(0.5),
            fontSize: 13,
            height: 1.5,
          ),
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFEF5350).withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _errorMessage!,
              style: const TextStyle(
                color: Color(0xFFEF5350),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
        const Spacer(flex: 1),
        // Download button
        SizedBox(
          width: double.infinity,
          height: 52,
          child: Material(
            color: const Color(0xFF4CAF50),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _downloadParams,
              child: Center(
                child: Text(
                  _errorMessage != null ? 'Retry Download' : 'Download Parameters',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
        const Spacer(flex: 2),
      ],
    );
  }

  /// Download in progress — show progress bar and status.
  Widget _buildDownloading() {
    return Column(
      children: [
        const Spacer(flex: 3),
        _buildHeader(),
        const Spacer(flex: 2),
        // File name
        if (_currentFile.isNotEmpty)
          Text(
            _currentFile,
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 14,
              fontFamily: 'monospace',
            ),
          ),
        const SizedBox(height: 16),
        // Progress bar
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _fileProgress,
            minHeight: 6,
            backgroundColor: Colors.white.withOpacity(0.1),
            valueColor:
                const AlwaysStoppedAnimation<Color>(Color(0xFF4CAF50)),
          ),
        ),
        const SizedBox(height: 12),
        // Percentage
        Text(
          '${(_fileProgress * 100).toStringAsFixed(1)}%',
          style: TextStyle(
            color: Colors.white.withOpacity(0.6),
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 8),
        // Status
        Text(
          _statusMessage,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withOpacity(0.4),
            fontSize: 12,
          ),
        ),
        const Spacer(flex: 3),
      ],
    );
  }

  /// Shared header: CLOAK title, divider, tagline.
  Widget _buildHeader() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // "CLOAK" title
        const Text(
          'CLOAK',
          style: TextStyle(
            fontFamily: _josefin,
            fontWeight: FontWeight.w300,
            fontSize: 42,
            color: Colors.white,
            letterSpacing: 12,
            height: 1,
          ),
        ),
        const SizedBox(height: 6),
        // "Wallet" subtitle
        Text(
          'Wallet',
          style: TextStyle(
            fontFamily: _josefin,
            fontWeight: FontWeight.w100,
            fontSize: 18,
            color: Colors.white.withOpacity(0.6),
            letterSpacing: 6,
          ),
        ),
        const SizedBox(height: 28),
        // Gradient divider
        Container(
          height: 1,
          width: 200,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.transparent,
                const Color(0xFF4CAF50).withOpacity(0.6),
                const Color(0xFF4CAF50),
                const Color(0xFF4CAF50).withOpacity(0.6),
                Colors.transparent,
              ],
              stops: const [0.0, 0.2, 0.5, 0.8, 1.0],
            ),
          ),
        ),
        const SizedBox(height: 24),
        // "Private By Default" tagline
        Text(
          'PRIVATE BY DEFAULT',
          style: TextStyle(
            fontFamily: _josefin,
            fontWeight: FontWeight.w300,
            fontSize: 13,
            color: Colors.white.withOpacity(0.45),
            letterSpacing: 5,
          ),
        ),
      ],
    );
  }
}
