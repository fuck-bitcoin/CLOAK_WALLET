import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'dart:typed_data';
import '../../utils/photo_decoder.dart';

class PhotoViewerPage extends StatelessWidget {
  final Uint8List photoBytes;
  
  PhotoViewerPage({required this.photoBytes});
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.maybePop(context),
        ),
        backgroundColor: Colors.transparent,
        iconTheme: IconThemeData(color: Colors.white),
      ),
      body: FutureBuilder<ui.Image?>(
        future: PhotoDecoder.decodePhoto(photoBytes),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(child: CircularProgressIndicator(color: Colors.white));
          }
          
          final image = snapshot.data!;
          return Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: CustomPaint(
                size: Size(image.width.toDouble(), image.height.toDouble()),
                painter: _ImagePainter(image),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ImagePainter extends CustomPainter {
  final ui.Image image;
  
  _ImagePainter(this.image);
  
  @override
  void paint(Canvas canvas, Size size) {
    final srcRect = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, srcRect, dstRect, Paint());
  }
  
  @override
  bool shouldRepaint(_ImagePainter oldDelegate) => oldDelegate.image != image;
}

