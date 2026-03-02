import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class ShrineSearchScreen extends StatefulWidget {
  final double? currentLat;
  final double? currentLng;

  const ShrineSearchScreen({super.key, this.currentLat, this.currentLng});

  @override
  State<ShrineSearchScreen> createState() => _ShrineSearchScreenState();
}

class _ShrineSearchScreenState extends State<ShrineSearchScreen> {
  final _controller = TextEditingController();
  List<QueryDocumentSnapshot>? _shrines;
  bool _loading = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onSearchChanged);
    // kick off an initial nearby fetch if location is known
    _performSearch();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onSearchChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _performSearch();
    });
  }

  Future<void> _performSearch() async {
    final text = _controller.text.trim();
    setState(() {
      _loading = true;
    });

    try {
      if (text.isEmpty) {
        _shrines = await _queryNearby();
      } else {
        _shrines = await _queryByName(text);
      }
    } catch (e) {
      // show nothing on error
      _shrines = [];
    }

    if (mounted) {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<List<QueryDocumentSnapshot>> _queryNearby() async {
    final lat = widget.currentLat;
    final lng = widget.currentLng;
    if (lat == null || lng == null) return [];

    const radiusMeters = 1000;
    final deltaLat = radiusMeters / 111320;
    final snapshot = await FirebaseFirestore.instance
        .collection('shrines')
        .where('lat', isGreaterThanOrEqualTo: lat - deltaLat)
        .where('lat', isLessThanOrEqualTo: lat + deltaLat)
        .limit(200)
        .get();
    return snapshot.docs;
  }

  Future<List<QueryDocumentSnapshot>> _queryByName(String text) async {
    final end = text + '\uf8ff';
    final snapshot = await FirebaseFirestore.instance
        .collection('shrines')
        .orderBy('name')
        .startAt([text])
        .endAt([end])
        .limit(50)
        .get();
    return snapshot.docs;
  }

  double _distanceMeters(double lat1, double lng1, double lat2, double lng2) {
    const R = 6371000;
    double toRad(double deg) => deg * (3.141592653589793 / 180.0);
    final dLat = toRad(lat2 - lat1);
    final dLng = toRad(lng2 - lng1);
    final a =
        (sin(dLat / 2) * sin(dLat / 2)) +
        cos(toRad(lat1)) * cos(toRad(lat2)) * (sin(dLng / 2) * sin(dLng / 2));
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('神社を選択')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: '検索',
                hintText: '神社名で検索',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final text = _controller.text.trim();
    if (_shrines == null) {
      return const Center(child: Text('検索してください'));
    }

    if (_shrines!.isEmpty) {
      if (text.isNotEmpty) {
        return ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: Text('新しい神社を追加: "${text}"'),
              onTap: () {
                Navigator.of(
                  context,
                ).pop({'id': null, 'name': text, 'distance': null});
              },
            ),
          ],
        );
      }
      return const Center(child: Text('候補が見つかりません'));
    }

    final items = List.of(_shrines!);
    if (widget.currentLat != null && widget.currentLng != null) {
      items.sort((a, b) {
        final aData = a.data() as Map<String, dynamic>;
        final bData = b.data() as Map<String, dynamic>;
        double aDist = double.infinity;
        double bDist = double.infinity;
        if (aData['lat'] is num && aData['lng'] is num) {
          aDist = _distanceMeters(
            widget.currentLat!,
            widget.currentLng!,
            (aData['lat'] as num).toDouble(),
            (aData['lng'] as num).toDouble(),
          );
        }
        if (bData['lat'] is num && bData['lng'] is num) {
          bDist = _distanceMeters(
            widget.currentLat!,
            widget.currentLng!,
            (bData['lat'] as num).toDouble(),
            (bData['lng'] as num).toDouble(),
          );
        }
        return aDist.compareTo(bDist);
      });
    }

    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, index) {
        final doc = items[index];
        final data = doc.data() as Map<String, dynamic>;
        final name = data['name'] as String? ?? '名前不明';
        double? dist;
        if (widget.currentLat != null &&
            widget.currentLng != null &&
            data['lat'] is num &&
            data['lng'] is num) {
          dist = _distanceMeters(
            widget.currentLat!,
            widget.currentLng!,
            (data['lat'] as num).toDouble(),
            (data['lng'] as num).toDouble(),
          ).roundToDouble();
        }
        return ListTile(
          title: Text(name),
          subtitle: dist != null ? Text('約 ${dist.round()}m') : null,
          onTap: () {
            Navigator.of(context).pop({
              'id': doc.id,
              'name': name,
              'distance': dist != null ? dist.round() : null,
            });
          },
        );
      },
    );
  }
}
