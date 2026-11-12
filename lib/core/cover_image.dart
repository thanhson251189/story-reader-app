import 'dart:io';

import 'package:flutter/material.dart';

class CoverImage extends StatelessWidget {
  final String? url;
  final double width;
  final double height;

  const CoverImage({
    super.key,
    required this.url,
    this.width = 48,
    this.height = 64,
  });

  @override
  Widget build(BuildContext context) {
    final icon = Icon(Icons.book, size: width * 0.8);
    final u = url;
    if (u == null || u.isEmpty) return icon;
    final image = u.startsWith('http')
        ? Image.network(u, fit: BoxFit.cover, errorBuilder: (_, _, _) => icon)
        : Image.file(
            File(u),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => icon,
          );
    return SizedBox(width: width, height: height, child: image);
  }
}
