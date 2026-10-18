import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../../../core/theme/app_theme.dart';

class RideRequestScreen extends StatefulWidget {
  const RideRequestScreen({super.key});

  @override
  State<RideRequestScreen> createState() => _RideRequestScreenState();
}

class _RideRequestScreenState extends State<RideRequestScreen> {
  final _destination = TextEditingController();
  final _http = http.Client();
  String _vehicle = 'bike';
  bool _busy = false;
  String? _message;
  String? _error;

  @override
  void dispose() {
    _destination.dispose();
    _http.close();
    super.dispose();
  }

  Future<Map<String, dynamic>?> _reverseGeocode(double lat, double lng) async {
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'format': 'jsonv2',
        'lat': '$lat',
        'lon': '$lng',
        'zoom': '18',
        'addressdetails': '1',
      });
      final response = await _http.get(uri, headers: const {
        'Accept': 'application/json',
        'User-Agent': 'ALLways-mobile-app/1.0',
      }).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final decoded = _decodeMap(response.body);
      return decoded;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _geocode(String destination) async {
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'format': 'jsonv2',
        'limit': '1',
        'q': destination,
      });
      final response = await _http.get(uri, headers: const {
        'Accept': 'application/json',
        'User-Agent': 'ALLways-mobile-app/1.0',
      }).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return null;
      final decoded = _decodeList(response.body);
      if (decoded.isEmpty || decoded.first is! Map) return null;
      return Map<String, dynamic>.from(decoded.first as Map);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _decodeMap(String source) {
    final decoded = _jsonDecode(source);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
  }

  List<dynamic> _decodeList(String source) {
    final decoded = _jsonDecode(source);
    return decoded is List ? decoded : const [];
  }

  dynamic _jsonDecode(String source) {
    // Keep parsing isolated so malformed third-party geocoding data is non-fatal.
    return jsonDecode(source);
  }

  Future<void> _requestRide() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      await context.push('/login');
      if (mounted && FirebaseAuth.instance.currentUser != null) {
        setState(() { _message = 'Signed in. You can now request your ride.'; });
      }
      return;
    }
    final destinationText = _destination.text.trim();
    if (destinationText.isEmpty) {
      setState(() => _error = 'Enter your destination.');
      return;
    }
    if (_busy) return;

    setState(() { _busy = true; _error = null; _message = 'Checking location permission…'; });
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        throw StateError('Enable location services to request a ride.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError('Location permission is required to request a ride.');
      }

      setState(() => _message = 'Finding your pickup location…');
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );

      setState(() => _message = 'Finding your destination…');
      final pickup = await _reverseGeocode(position.latitude, position.longitude);
      final destination = await _geocode(destinationText);
      final destinationLat = double.tryParse((destination?['lat'] ?? '').toString());
      final destinationLng = double.tryParse((destination?['lon'] ?? '').toString());

      final pickupAddress = (pickup?['display_name'] ?? 'Current location').toString();
      final destinationAddress =
          (destination?['display_name'] ?? destinationText).toString();

      final confirmationPin = (1000 + Random.secure().nextInt(9000)).toString();
      final ref = FirebaseFirestore.instance.collection('autoRideRequests').doc();
      await ref.set({
        'customerId': user.uid,
        'customerName': user.displayName ?? user.phoneNumber ?? user.email ?? 'Customer',
        'customerEmail': user.email ?? '',
        'customerPhone': user.phoneNumber ?? '',
        'pickupAddress': pickupAddress,
        'destinationAddress': destinationAddress,
        'pickupLatitude': position.latitude,
        'pickupLongitude': position.longitude,
        'destinationLatitude': destinationLat,
        'destinationLongitude': destinationLng,
        'rideType': _vehicle,
        'confirmationPin': confirmationPin,
        'status': 'searching',
        'requestedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      setState(() { _busy = false; _message = null; });
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.check_circle, color: AllwaysTheme.green, size: 42),
          title: const Text('Ride requested'),
          content: Text(
            'Your ride request was sent to ALLways. Your confirmation PIN is $confirmationPin. Share it with your assigned driver only when they arrive.',
          ),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                context.go('/');
              },
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } on FirebaseException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = null;
          _error = 'Could not request the ride (${error.code}). Please try again.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = null;
          _error = error.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Book a local ride')),
      body: SafeArea(
        child: ListView(
          key: const PageStorageKey<String>('customer-ride-request-scroll'),
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: const LinearGradient(
                  colors: [AllwaysTheme.green, AllwaysTheme.greenBright],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              padding: const EdgeInsets.all(20),
              child: const Row(children: [
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ALLways Travel', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                    SizedBox(height: 8),
                    Text('Go where you need to go.', style: TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.w900)),
                    SizedBox(height: 6),
                    Text('Your pickup location comes from your device GPS.', style: TextStyle(color: Colors.white)),
                  ],
                )),
                SizedBox(width: 8),
                Icon(Icons.two_wheeler, color: Colors.white, size: 46),
              ]),
            ),
            const SizedBox(height: 18),
            const Text('Choose a vehicle', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'bike', icon: Icon(Icons.two_wheeler), label: Text('Bike')),
                ButtonSegment(value: 'auto', icon: Icon(Icons.electric_rickshaw), label: Text('Auto')),
                ButtonSegment(value: 'car', icon: Icon(Icons.directions_car_outlined), label: Text('Car')),
              ],
              selected: {_vehicle},
              onSelectionChanged: _busy ? null : (value) => setState(() => _vehicle = value.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _destination,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _busy ? null : _requestRide(),
              decoration: const InputDecoration(
                labelText: 'Destination',
                hintText: 'Village, landmark or place name',
                prefixIcon: Icon(Icons.location_on_outlined),
              ),
            ),
            const SizedBox(height: 10),
            Card(child: const ListTile(
              leading: Icon(Icons.my_location, color: AllwaysTheme.green),
              title: Text('Pickup location'),
              subtitle: Text('Current device location will be used after permission is granted.'),
            )),
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!, style: const TextStyle(color: AllwaysTheme.green)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 14),
            FilledButton(
              onPressed: _busy ? null : _requestRide,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: _busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Request ride'),
              ),
            ),
            const SizedBox(height: 10),
            const Text('Location access is used to share pickup coordinates with your assigned driver.', style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
