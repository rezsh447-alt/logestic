import 'dart:convert'; import 'dart:math'; import 'package:flutter/material.dart'; import 'package:hive/hive.dart'; import 'package:hive_flutter/hive_flutter.dart'; import 'package:mobile_scanner/mobile_scanner.dart'; import 'package:http/http.dart' as http; import 'package:path_provider/path_provider.dart'; import 'package:latlong2/latlong.dart'; import 'package:flutter_map/flutter_map.dart'; import 'package:geolocator/geolocator.dart';

void main() async { WidgetsFlutterBinding.ensureInitialized(); final dir = await getApplicationDocumentsDirectory(); await Hive.initFlutter(dir.path); await Hive.openBox('packages'); runApp(MyApp()); }

class MyApp extends StatelessWidget { @override Widget build(BuildContext context) { return MaterialApp( title: 'مدیریت بسته‌ها', theme: ThemeData(primarySwatch: Colors.blue), home: PackageScreen(), ); } }

class PackageScreen extends StatefulWidget { @override _PackageScreenState createState() => _PackageScreenState(); }

class _PackageScreenState extends State<PackageScreen> { final _trackingNumberController = TextEditingController(); final _addressController = TextEditingController(); final _searchController = TextEditingController(); final box = Hive.box('packages');

String _filterStatus = "all";

String normalizeAddress(String input) { String addr = input; addr = addr.replaceAll(RegExp(r'\s+'), ' '); addr = addr.replaceAll(RegExp(r'[(),.-]'), ' '); return addr.trim(); }

void _addPackage() async { final trackingNumber = _trackingNumberController.text; String address = _addressController.text;

if (trackingNumber.isNotEmpty && address.isNotEmpty) {
  address = normalizeAddress(address);
  final coords = await _getLocationFromNeshan(address);

  box.put(trackingNumber, {
    "address": address,
    "lat": coords?['lat'],
    "lng": coords?['lng'],
    "status": "pending",
    "order": null,
  });

  _trackingNumberController.clear();
  _addressController.clear();
  setState(() {});
}

}

Future<Map<String, double>?> _getLocationFromNeshan(String address) async { final url = Uri.parse("https://api.neshan.org/v4/geocoding?address=$address"); final response = await http.get( url, headers: {"Api-Key": "YOUR_NESHAN_API_KEY"}, );

if (response.statusCode == 200) {
  final data = jsonDecode(response.body);
  if (data["location"] != null) {
    return {
      "lat": data["location"]["y"],
      "lng": data["location"]["x"],
    };
  }
}
return null;

}

void _optimizeRoute() async { final keys = box.keys.toList(); if (keys.isEmpty) return;

final position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
final Distance distance = Distance();

List<Map<String, dynamic>> packages = [];
for (var key in keys) {
  final pkg = box.get(key);
  if (pkg["lat"] != null && pkg["lng"] != null) {
    packages.add({
      "trackingNumber": key,
      "lat": pkg["lat"],
      "lng": pkg["lng"]
    });
  }
}

LatLng current = LatLng(position.latitude, position.longitude);
int order = 1;

while (packages.isNotEmpty) {
  packages.sort((a, b) => distance(
          current,
          LatLng(a["lat"], a["lng"]))
      .compareTo(distance(
          current,
          LatLng(b["lat"], b["lng"])),
  ));

  final nearest = packages.removeAt(0);
  final pkg = box.get(nearest["trackingNumber"]);
  box.put(nearest["trackingNumber"], {
    ...pkg,
    "order": order,
  });

  current = LatLng(nearest["lat"], nearest["lng"]);
  order++;
}

setState(() {});

}

void scanPackage() async { final result = await Navigator.push( context, MaterialPageRoute(builder: () => BarcodeScannerPage()), );

if (result != null) {
  final pkg = box.get(result);
  if (pkg != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("بسته ${pkg["order"] ?? "بدون ترتیب"}")),
    );
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("بسته‌ای با این کد پیدا نشد")),
    );
  }
}

}

@override Widget build(BuildContext context) { final keys = box.keys.toList();

final filteredKeys = keys.where((k) {
  final pkg = box.get(k);
  final searchText = _searchController.text;
  final matchesSearch = searchText.isEmpty ||
      k.toString().contains(searchText) ||
      pkg["address"].toString().contains(searchText);
  final matchesStatus = _filterStatus == "all" || pkg["status"] == _filterStatus;
  return matchesSearch && matchesStatus;
}).toList();

int deliveredCount = keys.where((k) => box.get(k)["status"] == "delivered").length;

return Scaffold(
  appBar: AppBar(title: Text("مدیریت بسته‌ها")),
  body: Padding(
    padding: EdgeInsets.all(8),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(labelText: "جستجو"),
                onChanged: (_) => setState(() {}),
              ),
            ),
            DropdownButton<String>(
              value: _filterStatus,
              items: [
                DropdownMenuItem(value: "all", child: Text("همه")),
                DropdownMenuItem(value: "pending", child: Text("در انتظار")),
                DropdownMenuItem(value: "delivered", child: Text("تحویل شده")),
              ],
              onChanged: (val) {
                setState(() => _filterStatus = val!);
              },
            )
          ],
        ),
        Text("کل بسته‌ها: ${keys.length}, تحویل شده: $deliveredCount"),
        TextField(
          controller: _trackingNumberController,
          decoration: InputDecoration(labelText: "شماره مرسوله"),
        ),
        TextField(
          controller: _addressController,
          decoration: InputDecoration(labelText: "آدرس"),
        ),
        Row(
          children: [
            ElevatedButton(
              onPressed: _addPackage,
              child: Text("افزودن"),
            ),
            SizedBox(width: 10),
            ElevatedButton(
              onPressed: _optimizeRoute,
              child: Text("بهینه‌سازی مسیر"),
            ),
          ],
        ),
        Expanded(
          child: ListView.builder(
            itemCount: filteredKeys.length,
            itemBuilder: (context, index) {
              final trackingNumber = filteredKeys[index];
              final pkg = box.get(trackingNumber);
              return ListTile(
                title: Text("${pkg["order"] != null ? "#${pkg["order"]} - " : ""} $trackingNumber"),
                subtitle: Text("${pkg["address"]}"),
                trailing: Text(pkg["status"]),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PackageDetailPage(
                        trackingNumber: trackingNumber,
                        pkg: pkg,
                      ),
                    ),
                  ).then((_) => setState(() {}));
                },
              );
            },
          ),
        ),
      ],
    ),
  ),
  floatingActionButton: FloatingActionButton(
    onPressed: _scanPackage,
    child: Icon(Icons.qr_code_scanner),
  ),
);

} }

class BarcodeScannerPage extends StatelessWidget { final MobileScannerController controller = MobileScannerController();

@override Widget build(BuildContext context) { return Scaffold( appBar: AppBar(title: Text("اسکن بارکد")), body: MobileScanner( controller: controller, onDetect: (capture) { final barcodes = capture.barcodes; if (barcodes.isNotEmpty) { final value = barcodes.first.rawValue; if (value != null) Navigator.pop(context, value); } }, ), ); } }

class PackageDetailPage extends StatefulWidget { final String trackingNumber; final Map pkg;

PackageDetailPage({required this.trackingNumber, required this.pkg});

@override _PackageDetailPageState createState() => _PackageDetailPageState(); }

class _PackageDetailPageState extends State<PackageDetailPage> { final box = Hive.box('packages');

void _toggleStatus() { final pkg = widget.pkg; final newStatus = pkg["status"] == "pending" ? "delivered" : "pending"; box.put(widget.trackingNumber, {...pkg, "status": newStatus}); setState(() => widget.pkg["status"] = newStatus); }

@override Widget build(BuildContext context) { final pkg = widget.pkg;

return Scaffold(
  appBar: AppBar(title: Text("جزئیات بسته")),
  body: Padding(
    padding: EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("شماره مرسوله: ${widget.trackingNumber}"),
        Text("آدرس: ${pkg["address"]}"),
        Text("وضعیت: ${pkg["status"]}"),
        if (pkg["order"] != null) Text("ترتیب: ${pkg["order"]}"),
        SizedBox(height: 20),
        ElevatedButton(
          onPressed: _toggleStatus,
          child: Text(pkg["status"] == "pending" ? "تحویل شد" : "بازگشت به در انتظار"),
        )
      ],
    ),
  ),
);

} }


