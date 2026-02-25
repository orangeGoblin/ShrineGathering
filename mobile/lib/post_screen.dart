import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

class PostScreen extends StatefulWidget {
  const PostScreen({super.key});

  @override
  State<PostScreen> createState() => _PostScreenState();
}

class _PostScreenState extends State<PostScreen> {
  final _commentController = TextEditingController();
  final _picker = ImagePicker();

  File? _imageFile;
  double? _latitude;
  double? _longitude;

  String? _shrineId;
  String? _shrineName;
  int? _shrineDistance;

  bool _loadingLocation = false;
  bool _loadingShrine = false;
  bool _posting = false;

  final Set<String> _selectedTags = {};

  static const _tags = [
    {"key": "goshuin", "label": "御朱印あり"},
    {"key": "cat", "label": "猫"},
    {"key": "quiet", "label": "静か"},
    {"key": "crowded", "label": "混雑"},
    {"key": "seasonal", "label": "季節"},
  ];

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    setState(() {
      _imageFile = File(picked.path);
      _latitude = null;
      _longitude = null;
      _shrineId = null;
      _shrineName = null;
      _shrineDistance = null;
    });

    await _resolveLocationFromExifOrGps(picked);
  }

  Future<void> _resolveLocationFromExifOrGps(XFile picked) async {
    setState(() {
      _loadingLocation = true;
    });
    try {
      final bytes = await picked.readAsBytes();
      final exif = await readExifFromBytes(bytes as Uint8List);

      final lat = _extractGpsCoordinate(
        exif,
        'GPS GPSLatitude',
        'GPS GPSLatitudeRef',
      );
      final lng = _extractGpsCoordinate(
        exif,
        'GPS GPSLongitude',
        'GPS GPSLongitudeRef',
      );

      if (lat != null && lng != null) {
        setState(() {
          _latitude = lat;
          _longitude = lng;
        });
      } else {
        await _getLocationFromDevice();
      }
    } catch (_) {
      await _getLocationFromDevice();
    } finally {
      if (mounted) {
        setState(() {
          _loadingLocation = false;
        });
      }
    }

    if (_latitude != null && _longitude != null) {
      await _detectShrine();
    }
  }

  double? _extractGpsCoordinate(
    Map<String, IfdTag> exif,
    String valueKey,
    String refKey,
  ) {
    final valueTag = exif[valueKey];
    if (valueTag == null) return null;

    final refTag = exif[refKey];
    final ref = refTag?.printable.trim() ?? 'N';

    final values = valueTag.values;
    if (values == null || values.length < 3) return null;

    double toDouble(dynamic v) {
      if (v is num) return v.toDouble();
      final s = v.toString();
      if (s.contains('/')) {
        final parts = s.split('/');
        final nume = double.tryParse(parts[0]);
        final deno = double.tryParse(parts[1]);
        if (nume != null && deno != null && deno != 0) {
          return nume / deno;
        }
      }
      return double.tryParse(s) ?? 0;
    }

    final deg = toDouble(values[0]);
    final min = toDouble(values[1]);
    final sec = toDouble(values[2]);
    var result = deg + (min / 60.0) + (sec / 3600.0);

    if (ref == 'S' || ref == 'W') {
      result = -result;
    }
    return result;
  }

  Future<void> _getLocationFromDevice() async {
    // 位置情報パーミッション
    final status = await Permission.location.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('位置情報が取得できませんでした。後で手動検索機能を追加予定です。'),
          ),
        );
      }
      return;
    }

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('位置情報サービスを有効にしてください。')),
        );
      }
      return;
    }

    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    setState(() {
      _latitude = position.latitude;
      _longitude = position.longitude;
    });
  }

  Future<void> _detectShrine() async {
    if (_latitude == null || _longitude == null) return;

    setState(() {
      _loadingShrine = true;
    });

    try {
      final callable =
          FirebaseFunctions.instance.httpsCallable('detectShrine');
      final result = await callable.call<Map<String, dynamic>>({
        'lat': _latitude,
        'lng': _longitude,
      });

      final data = result.data;
      setState(() {
        _shrineId = data['shrineId'] as String?;
        _shrineName = data['name'] as String?;
        _shrineDistance = (data['distance'] as num?)?.toInt();
      });

      if (_shrineId == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('近くに神社候補が見つかりませんでした。'),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('神社自動特定に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _loadingShrine = false;
        });
      }
    }
  }

  Future<void> _submit() async {
    if (_imageFile == null || _posting) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ログインが必要です。')),
      );
      return;
    }

    setState(() {
      _posting = true;
    });

    try {
      final postsCol = FirebaseFirestore.instance.collection('posts');
      final docRef = postsCol.doc();
      final postId = docRef.id;

      // Storage へアップロード
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('posts/${user.uid}/$postId.jpg');
      await storageRef.putFile(_imageFile!);
      final imageUrl = await storageRef.getDownloadURL();

      await docRef.set({
        'userId': user.uid,
        'shrineId': _shrineId,
        'shrineName': _shrineName,
        'text': _commentController.text,
        'photoUrls': [imageUrl],
        'tags': _selectedTags.toList(),
        'visibility': 'public',
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('投稿しました。')),
        );
        Navigator.of(context).maybePop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('投稿に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _posting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPost = _imageFile != null && !_posting;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ShrinePost'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              onTap: _pickImage,
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade400),
                  ),
                  child: _imageFile == null
                      ? const Center(
                          child: Text('タップして写真を選択'),
                        )
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(
                            _imageFile!,
                            fit: BoxFit.cover,
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_loadingLocation)
              const Text('位置情報を取得中...'),
            if (_loadingShrine)
              const Text('近くの神社を検索中...'),
            const SizedBox(height: 12),
            _buildShrineCard(),
            const SizedBox(height: 16),
            TextField(
              controller: _commentController,
              maxLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'コメント（任意）',
              ),
            ),
            const SizedBox(height: 16),
            const Text('タグ'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: _tags.map((tag) {
                final key = tag['key'] as String;
                final label = tag['label'] as String;
                final selected = _selectedTags.contains(key);
                return FilterChip(
                  selected: selected,
                  label: Text(label),
                  onSelected: (value) {
                    setState(() {
                      if (value) {
                        _selectedTags.add(key);
                      } else {
                        _selectedTags.remove(key);
                      }
                    });
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: canPost ? _submit : null,
              child: _posting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('投稿する'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShrineCard() {
    if (_shrineName == null) {
      return Card(
        child: ListTile(
          title: const Text('神社候補'),
          subtitle: const Text('写真または位置情報から自動推定します'),
          trailing: TextButton(
            onPressed: () {
              // 後で実装するためダミー
            },
            child: const Text('別の神社を探す'),
          ),
        ),
      );
    }

    return Card(
      child: ListTile(
        title: Text(_shrineName!),
        subtitle: _shrineDistance != null
            ? Text('約 ${_shrineDistance}m 先')
            : null,
        trailing: TextButton(
          onPressed: () {
            // 後で実装するためダミー
          },
          child: const Text('別の神社を探す'),
        ),
      ),
    );
  }
}

