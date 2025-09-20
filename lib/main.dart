// main.dart
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:neshan_flutter/neshan_flutter.dart';
import 'package:geolocator/geolocator.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('packages');
  runApp(MyApp());
}

// ====== تنظیم کلید نشن ======
const String NESHAAN_API_KEY = "service.da7638207310466f9c8ca0b620625def";
// ============================

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مدیریت بسته‌ها',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: PackageScreen(),
    );
  }
}

class PackageScreen extends StatefulWidget {
  @override
  _PackageScreenState createState() => _PackageScreenState();
}

class _PackageScreenState extends State<PackageScreen> {
  final box = Hive.box('packages');

  final _trackingNumberController = TextEditingController();
  final _addressController = TextEditingController();

  NeshanMapController? _mapController;
  Polyline? _combinedRoute;
  Set<Polyline> _polylines = {};
  Set<Marker> _markers = {};

  String normalizeAddress(String input) {
    String addr = input;
    addr = addr.replaceAll(RegExp(r'\s+'), ' ');
    addr = addr.replaceAll(RegExp(r'[(),.-]'), ' ');
    List<String> blacklist = [
      "ساختمان", "برج", "پاساژ", "مجتمع", "طبقه", "واحد", "بلوک",
      "روبروی", "مقابل", "جنب", "کنار", "بعد", "بالای", "پایین",
      "انتهای", "ابتدای", "شرکت", "فروشگاه", "دفتر"
    ];
    for (var word in blacklist) {
      addr = addr.replaceAll(RegExp("$word.*"), "");
    }
    return addr.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Future<Map<String, double>?> _getLocationFromNeshan(String address) async {
    try {
      final encoded = Uri.encodeComponent(address);
      final url = Uri.parse("https://api.neshan.org/v4/geocoding?address=$encoded");
      final response = await http.get(url, headers: {"Api-Key": NESHAAN_API_KEY});
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data != null && data["location"] != null) {
          return {"lat": data["location"]["y"] * 1.0, "lng": data["location"]["x"] * 1.0};
        }
        if (data is List && data.isNotEmpty && data[0]["location"] != null) {
          return {"lat": data[0]["location"]["y"] * 1.0, "lng": data[0]["location"]["x"] * 1.0};
        }
      }
    } catch (e) {
      print("Geocoding error: $e");
    }
    return null;
  }

  Future<String?> _getDirectionsOverviewPolyline(LatLng origin, LatLng destination) async {
    try {
      final url = Uri.parse(
          "https://api.neshan.org/v4/direction?origin=${origin.latitude},${origin.longitude}&destination=${destination.latitude},${destination.longitude}");
      final resp = await http.get(url, headers: {"Api-Key": NESHAAN_API_KEY});
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data != null && data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          if (route['overview_polyline'] != null && route['overview_polyline']['points'] != null) {
            return route['overview_polyline']['points'];
          }
        }
      } else {
        print("Direction status: ${resp.statusCode} ${resp.body}");
      }
    } catch (e) {
      print("Direction error: $e");
    }
    return null;
  }

  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> points = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }

  double _distance(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371;
    double dLat = (lat2 - lat1) * pi / 180;
    double dLon = (lon2 - lon1) * pi / 180;
    double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dLon / 2) * sin(dLon / 2);
    double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  Future<void> _assignNumbersByNearest({bool useCurrentLocationAsStart = false}) async {
    final keys = box.keys.toList();
    if (keys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("بسته‌ای موجود نیست")));
      return;
    }

    List<Map<String, dynamic>> packages = [];
    for (var k in keys) {
      final pkg = box.get(k);
      if (pkg != null && pkg['lat'] != null && pkg['lng'] != null) {
        packages.add({
          "tracking": k,
          "lat": pkg['lat'],
          "lng": pkg['lng'],
          "data": Map<String, dynamic>.from(pkg),
        });
      }
    }

    if (packages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("هیچ بسته‌ای با مختصات ثبت نشده")));
      return;
    }

    LatLng currentPoint = LatLng(packages[0]['lat'], packages[0]['lng']);
    if (useCurrentLocationAsStart) {
      try {
        final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
        currentPoint = LatLng(pos.latitude, pos.longitude);
      } catch (e) {
        print("Could not get current location: $e");
      }
    }

    List<Map<String, dynamic>> remaining = List.from(packages);
    List<Map<String, dynamic>> ordered = [];

    while (remaining.isNotEmpty) {
      remaining.sort((a, b) {
        double da = _distance(currentPoint.latitude, currentPoint.longitude, a['lat'], a['lng']);
        double db = _distance(currentPoint.latitude, currentPoint.longitude, b['lat'], b['lng']);
        return da.compareTo(db);
      });
      final next = remaining.removeAt(0);
      ordered.add(next);
      currentPoint = LatLng(next['lat'], next['lng']);
    }

    for (int i = 0; i < ordered.length; i++) {
      final tracking = ordered[i]['tracking'];
      final pkg = ordered[i]['data'];
      pkg['seq'] = i + 1;
      await box.put(tracking, pkg);
    }

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text("شماره‌گذاری بر اساس نزدیک‌ترین مسیر انجام شد")));
    setState(() {});
  }

  Future<void> _buildAndShowOptimizedRoute({bool useCurrentLocationAsStart = false}) async {
    final keys = box.keys.toList();
    if (keys.isEmpty) return;

    List<Map<String, dynamic>> packages = [];
    for (var k in keys) {
      final pkg = box.get(k);
      if (pkg != null && pkg['lat'] != null && pkg['lng'] != null) {
        packages.add({
          "tracking": k,
          "lat": pkg['lat'],
          "lng": pkg['lng'],
          "data": Map<String, dynamic>.from(pkg),
        });
      }
    }
    if (packages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("هیچ بسته‌ای با مختصات ثبت نشده")));
      return;
    }

    LatLng currentPoint = LatLng(packages[0]['lat'], packages[0]['lng']);
    if (useCurrentLocationAsStart) {
      try {
        final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
        currentPoint = LatLng(pos.latitude, pos.longitude);
      } catch (e) {
        print("Could not get current location: $e");
      }
    }

    List<Map<String, dynamic>> remaining = List.from(packages);
    List<Map<String, dynamic>> ordered = [];
    while (remaining.isNotEmpty) {
      remaining.sort((a, b) {
        double da = _distance(currentPoint.latitude, currentPoint.longitude, a['lat'], a['lng']);
        double db = _distance(currentPoint.latitude, currentPoint.longitude, b['lat'], b['lng']);
        return da.compareTo(db);
      });
      final next = remaining.removeAt(0);
      ordered.add(next);
      currentPoint = LatLng(next['lat'], next['lng']);
    }

    for (int i = 0; i < ordered.length; i++) {
      final tracking = ordered[i]['tracking'];
      final pkg = ordered[i]['data'];
      pkg['seq'] = i + 1;
      await box.put(tracking, pkg);
    }

    List<LatLng> combinedPoints = [];
    for (int i = 0; i < ordered.length - 1; i++) {
      final a = LatLng(ordered[i]['lat'], ordered[i]['lng']);
      final b = LatLng(ordered[i + 1]['lat'], ordered[i + 1]['lng']);
      final polyEncoded = await _getDirectionsOverviewPolyline(a, b);
      if (polyEncoded != null) {
        final segment = _decodePolyline(polyEncoded);
        if (combinedPoints.isNotEmpty &&
            (combinedPoints.last.latitude == segment.first.latitude &&
                combinedPoints.last.longitude == segment.first.longitude)) {
          combinedPoints.addAll(segment.skip(1));
        } else {
          combinedPoints.addAll(segment);
        }
      } else {
        if (combinedPoints.isEmpty) combinedPoints.add(a);
        combinedPoints.add(b);
      }
    }

    if (ordered.length == 1) {
      combinedPoints = [LatLng(ordered[0]['lat'], ordered[0]['lng'])];
    }

    setState(() {
      _polylines.clear();
      _markers.clear();

      if (combinedPoints.isNotEmpty) {
        _polylines.add(Polyline(points: combinedPoints, color: Colors.blue, width: 5.0));
      }

      for (var item in ordered) {
        final seq = item['data']['seq'] ?? '?';
        _markers.add(Marker(
          point: LatLng(item['lat'], item['lng']),
          title: "بسته $seq",
          subtitle: item['tracking'],
        ));
      }
    });

    if (_mapController != null && combinedPoints.isNotEmpty) {
      double minLat = combinedPoints.map((p) => p.latitude).reduce(min);
      double maxLat = combinedPoints.map((p) => p.latitude).reduce(max);
      double minLng = combinedPoints.map((p) => p.longitude).reduce(min);
      double maxLng = combinedPoints.map((p) => p.longitude).reduce(max);

      final sw = LatLng(minLat, minLng);
      final ne = LatLng(maxLat, maxLng);
      try {
        _mapController!.animateCamera(CameraUpdate.newLatLngBounds(LatLngBounds(southwest: sw, northeast: ne), 80));
      } catch (e) {
        print("animate camera error: $e");
      }
    }

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("مسیر بهینه روی نقشه نمایش داده شد")));
  }

  Future<void> _addPackageFromInputs() async {
    final tracking = _trackingNumberController.text.trim();
    final addressFull = _addressController.text.trim();
    if (tracking.isEmpty || addressFull.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("شماره مرسوله و آدرس لازم است")));
      return;
    }
    final addressClean = normalizeAddress(addressFull);
    final coords = await _getLocationFromNeshan(addressClean);
    await box.put(tracking, {
      "address_full": addressFull,
      "address_clean": addressClean,
      "lat": coords?['lat'],
      "lng": coords?['lng'],
      "receiver_name": "نامشخص",
      "receiver_phone": "نامشخص",
      "status": "pending",
    });
    _trackingNumberController.clear();
    _addressController.clear();
    setState(() {});
  }

  Future<void> _scanBarcodeAndShowSeq() async {
    final scanned = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BarcodeScannerPage()),
    );
    if (scanned != null) {
      final pkg = box.get(scanned);
      if (pkg != null) {
        final seq = pkg['seq'] ?? 'نامشخص';
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: Text("نتیجه اسکن"),
            content: Text("این بارکد مربوط به بسته شماره $seq است.\nمرسوله: $scanned"),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text("باشه"))],
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("بسته‌ای با این شماره مرسوله پیدا نشد")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final keys = box.keys.toList();
    return Scaffold(
      appBar: AppBar(
        title: Text("مدیریت بسته‌ها"),
        actions: [
          IconButton(onPressed: _scanBarcodeAndShowSeq, icon: Icon(Icons.qr_code_scanner)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                controller: _trackingNumberController,
                decoration: InputDecoration(labelText: "شماره مرسوله"),
              ),
              SizedBox(height: 8),
              TextField(
                controller: _addressController,
                decoration: InputDecoration(labelText: "آدرس (همین آدرس برای نمایش به کاربر ذخیره می‌شود)"),
              ),
              SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(onPressed: _addPackageFromInputs, child: Text("افزودن بسته")),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                        onPressed: () => _assignNumbersByNearest(useCurrentLocationAsStart: false),
                        child: Text("تخصیص شماره (شروع از اولین)")),
                  ),
                ],
              ),
              SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                        onPressed: () => _assignNumbersByNearest(useCurrentLocationAsStart: true),
                        child: Text("تخصیص شماره (شروع از موقعیت من)")),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                        onPressed: () => _buildAndShowOptimizedRoute(useCurrentLocationAsStart: true),
                        child: Text("نمایش مسیر بهینه روی نقشه")),
                  ),
                ],
              ),
            ]),
          ),
          Divider(),
          Expanded(
            flex: 2,
            child: NeshanMap(
              options: NeshanMapOptions(
                apiKey: NESHAAN_API_KEY,
                center: LatLng(35.7, 51.4),
                zoom: 12,
              ),
              onMapReady: (controller) {
                _mapController = controller;
                _markers.clear();
                for (var k in keys) {
                  final pkg = box.get(k);
                  if (pkg != null && pkg['lat'] != null && pkg['lng'] != null) {
                    final seq = pkg['seq'];
                    _markers.add(Marker(
                      point: LatLng(pkg['lat'], pkg['lng']),
                      title: seq != null ? "بسته $seq" : "مرسوله",
                      subtitle: "$k\n${pkg['address_full'] ?? ''}",
                      draggable: true,
                      onDragEnd: (newPos) async {
                        final p = Map<String, dynamic>.from(pkg);
                        p['lat'] = newPos.latitude;
                        p['lng'] = newPos.longitude;
                        await box.put(k, p);
                        setState(() {});
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("مختصات بسته به‌روزرسانی شد: ${newPos.latitude}, ${newPos.longitude}")));
                      },
                    ));
                  }
                }
                controller.addPolylines(_polylines.toList());
                controller.addMarkers(_markers.toList());
              },
              polylines: _polylines,
              markers: _markers.toList(),
            ),
          ),
          Divider(),
          Expanded(
            flex: 1,
            child: ListView.builder(
              itemCount: keys.length,
              itemBuilder: (context, i) {
                final tracking = keys[i];
                final pkg = box.get(tracking);
                return ListTile(
                  title: Text("بسته ${pkg['seq'] ?? '-'}  —  $tracking"),
                  subtitle: Text(pkg['address_full'] ?? "آدرس ندارد"),
                  trailing: Text(pkg['status'] ?? ''),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PackageDetailPage(trackingNumber: tracking, pkg: Map<String, dynamic>.from(pkg)),
                      ),
                    ).then((_) => setState(() {}));
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class BarcodeScannerPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("اسکن بارکد")),
      body: MobileScanner(
        onDetect: (capture) {
          final List<Barcode> barcodes = capture.barcodes;
          if (barcodes.isNotEmpty) {
            final value = barcodes.first.rawValue;
            if (value != null && value.isNotEmpty) {
              Navigator.pop(context, value);
            }
          }
        },
      ),
    );
  }
}

class PackageDetailPage extends StatefulWidget {
  final String trackingNumber;
  final Map<String, dynamic> pkg;
  PackageDetailPage({required this.trackingNumber, required this.pkg});

  @override
  _PackageDetailPageState createState() => _PackageDetailPageState();
}

class _PackageDetailPageState extends State<PackageDetailPage> {
  final box = Hive.box('packages');
  late Map<String, dynamic> pkg;

  @override
  void initState() {
    super.initState();
    pkg = widget.pkg;
  }

  Future<void> _toggleStatus() async {
    pkg['status'] = (pkg['status'] == 'delivered') ? 'pending' : 'delivered';
    await box.put(widget.trackingNumber, pkg);
    setState(() {});
  }

  Future<void> _updateCoordsManually() async {
    final latController = TextEditingController(text: pkg['lat']?.toString() ?? '');
    final lngController = TextEditingController(text: pkg['lng']?.toString() ?? '');
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text("به‌روزرسانی مختصات"),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: latController, decoration: InputDecoration(labelText: "lat")),
          TextField(controller: lngController, decoration: InputDecoration(labelText: "lng")),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text("لغو")),
          TextButton(
              onPressed: () async {
                final newLat = double.tryParse(latController.text);
                final newLng = double.tryParse(lngController.text);
                if (newLat != null && newLng != null) {
                  pkg['lat'] = newLat;
                  pkg['lng'] = newLng;
                  await box.put(widget.trackingNumber, pkg);
                  setState(() {});
                  Navigator.pop(context);
                }
              },
              child: Text("ذخیره"))
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("جزئیات بسته ${pkg['seq'] ?? ''}"),
      ),
      body: Padding(
        padding: EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("شماره مرسوله: ${widget.trackingNumber}", style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          Text("آدرس کامل: ${pkg['address_full'] ?? ''}"),
          SizedBox(height: 8),
          Text("آدرس تمیز (برای نشن): ${pkg['address_clean'] ?? ''}"),
          SizedBox(height: 8),
          Text("گیرنده: ${pkg['receiver_name'] ?? ''}"),
          SizedBox(height: 8),
          Text("تلفن: ${pkg['receiver_phone'] ?? ''}"),
          SizedBox(height: 8),
          Text("وضعیت: ${pkg['status'] ?? ''}"),
          SizedBox(height: 12),
          Row(children: [
            ElevatedButton(onPressed: _toggleStatus, child: Text(pkg['status'] == 'delivered' ? "برگردوندن" : "تحویل شد")),
            SizedBox(width: 8),
            ElevatedButton(onPressed: _updateCoordsManually, child: Text("اصلاح مختصات")),
          ])
        ]),
      ),
    );
  }
}