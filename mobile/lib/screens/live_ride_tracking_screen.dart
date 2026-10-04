import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

const _mapboxPublicToken = String.fromEnvironment('MAPBOX_PUBLIC_TOKEN');
const _mapboxTilesUrl = 'https://api.mapbox.com/styles/v1/mapbox/streets-v12/tiles/256/{z}/{x}/{y}?access_token=' + _mapboxPublicToken;

import 'package:url_launcher/url_launcher.dart';

class LiveRideTrackingScreen extends StatefulWidget {
  final String rideId;
  final bool isRider;
  const LiveRideTrackingScreen({super.key, required this.rideId, this.isRider = false});
  @override State<LiveRideTrackingScreen> createState() => _LiveRideTrackingScreenState();
}

Future<void> _triggerPhoneCall(String phoneNumber) async {
  if (phoneNumber.trim().isEmpty) return;
  final uri = Uri(scheme: 'tel', path: phoneNumber.trim());
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri);
  }
}

class _LiveRideTrackingScreenState extends State<LiveRideTrackingScreen> {
  final MapController _mapController = MapController();
  List<LatLng> _routePoints = const [];
  LatLng? _driverLocation;
  LatLng? _customerLocation;
  LatLng? _pickupLocation;
  LatLng? _destinationLocation;
  double _markerRotation = 0.0;
  String _contactPhone = '';
  String _rideStatus = 'searching';
  String _confirmationPin = '';
  bool _cameraFitted = false;
  bool _mapReady = false;
  StreamSubscription<Position>? _customerLocationSubscription;
  bool _customerLocationStarted = false;
  double? _distanceToOtherKm;
  String _etaText = 'Updating…';
  List<Map<String,dynamic>> _navSteps = const [];
  double? _routeDistanceMeters;
  double? _routeDurationSeconds;
  DateTime? _lastRouteUpdate;
  bool _routeLoading = false;
  DateTime? _lastCameraMove;
  bool _userMovedMap = false;
  int _activeNavIndex = 0;

  @override
  void initState() {
    super.initState();
    _initRideStream();
  }

  @override
  void dispose() {
    _customerLocationSubscription?.cancel();
    super.dispose();
  }

  void _initRideStream() {
    FirebaseFirestore.instance.collection('autoRideRequests').doc(widget.rideId).snapshots().listen((doc) {
      if (!mounted || !doc.exists || doc.data() == null) return;
      final data = doc.data()!;
      LatLng? newPickup;
      LatLng? newDestination;
      LatLng? newDriver;
      LatLng? newCustomer;

      final pickupLat = data['pickupLat'] ?? data['pickupLatitude'];
      final pickupLng = data['pickupLng'] ?? data['pickupLongitude'];
      final destLat = data['destLat'] ?? data['destinationLatitude'];
      final destLng = data['destLng'] ?? data['destinationLongitude'];
      if (pickupLat is num && pickupLng is num) {
        newPickup = LatLng(pickupLat.toDouble(), pickupLng.toDouble());
      }
      if (destLat is num && destLng is num) {
        newDestination = LatLng(destLat.toDouble(), destLng.toDouble());
      }
      if (data['driverLat'] is num && data['driverLng'] is num) {
        newDriver = LatLng((data['driverLat'] as num).toDouble(), (data['driverLng'] as num).toDouble());
      }
      if (data['customerLat'] is num && data['customerLng'] is num) {
        newCustomer = LatLng((data['customerLat'] as num).toDouble(), (data['customerLng'] as num).toDouble());
      } else if (data['pickupLatitude'] is num && data['pickupLongitude'] is num) {
        newCustomer = LatLng((data['pickupLatitude'] as num).toDouble(), (data['pickupLongitude'] as num).toDouble());
      }

      final routeChanged = _pickupLocation?.latitude != newPickup?.latitude ||
          _pickupLocation?.longitude != newPickup?.longitude ||
          _destinationLocation?.latitude != newDestination?.latitude ||
          _destinationLocation?.longitude != newDestination?.longitude;

      setState(() {
        _rideStatus = (data['status'] ?? 'searching').toString();
        _confirmationPin = (data['confirmationPin'] ?? '').toString().trim();
        _contactPhone = widget.isRider ? (data['customerPhone'] ?? '').toString() : (data['driverPhone'] ?? '').toString();
        _pickupLocation = newPickup;
        _destinationLocation = newDestination;
        if (newDriver != null) {
          if (_driverLocation != null) _markerRotation = _getBearing(_driverLocation!, newDriver);
          _driverLocation = newDriver;
        }
        _customerLocation = newCustomer;
        final other = widget.isRider ? newCustomer : newDriver;
        final me = widget.isRider ? newDriver : newCustomer;
        if (other != null && me != null) {
          final meters = Geolocator.distanceBetween(me.latitude, me.longitude, other.latitude, other.longitude);
          _distanceToOtherKm = meters / 1000;
          final minutes = math.max(1, (meters / 1000 / 25 * 60).round());
          _etaText = minutes < 60 ? minutes.toString() + ' min' : (minutes ~/ 60).toString() + 'h ' + (minutes % 60).toString() + 'm';
        }
      });
      if (!widget.isRider && !_customerLocationStarted) _startCustomerLocationBroadcast();

      if (newPickup != null && newDestination != null) {
        final status=(data['status']??'searching').toString().toLowerCase();
        final target=(status=='accepted'||status=='searching') ? newPickup : newDestination;
        final startPoint=widget.isRider ? newDriver : newCustomer;
        if(startPoint!=null && (_routePoints.isEmpty || routeChanged || _lastRouteUpdate==null || DateTime.now().difference(_lastRouteUpdate!)>const Duration(seconds:20))) _loadOSRMRoute(startPoint,target);
      }
      _fitCameraIfReady();
    });
  }

  Future<void> _startCustomerLocationBroadcast() async {
    _customerLocationStarted = true;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return;
      final settings = Platform.isAndroid
          ? AndroidSettings(accuracy: LocationAccuracy.high, distanceFilter: 10, intervalDuration: const Duration(seconds: 10), foregroundNotificationConfig: const ForegroundNotificationConfig(notificationTitle: 'ALLways live ride tracking', notificationText: 'ALLways is sharing your live location for this active ride.', notificationChannelName: 'ALLways Live Ride Tracking', enableWakeLock: true, setOngoing: true))
          : const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10);
      final first = await Geolocator.getCurrentPosition(locationSettings: settings);
      await FirebaseFirestore.instance.collection('autoRideRequests').doc(widget.rideId).set({'customerLat': first.latitude, 'customerLng': first.longitude, 'customerLocationUpdatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      _customerLocationSubscription = Geolocator.getPositionStream(locationSettings: settings).listen((position) async {
        try {
          await FirebaseFirestore.instance.collection('autoRideRequests').doc(widget.rideId).set({'customerLat': position.latitude, 'customerLng': position.longitude, 'customerLocationUpdatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
        } catch (_) {}
      });
    } catch (_) {}
  }

  double _getBearing(LatLng start, LatLng end) {
    final lat1 = start.latitude * math.pi / 180;
    final lng1 = start.longitude * math.pi / 180;
    final lat2 = end.latitude * math.pi / 180;
    final lng2 = end.longitude * math.pi / 180;
    final dLon = lng2 - lng1;
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  Future<void> _loadOSRMRoute(LatLng start, LatLng end) async {
    if (_routeLoading) return;
    if (_lastRouteUpdate != null && DateTime.now().difference(_lastRouteUpdate!) < const Duration(seconds: 8)) return;
    _routeLoading = true;
    try {
      final url = Uri.parse("https://router.project-osrm.org/route/v1/driving/\${start.longitude},\${start.latitude};\${end.longitude},\${end.latitude}?overview=full&geometries=geojson&steps=true&annotations=true");
      final res = await http.get(url);
      if (!mounted || res.statusCode != 200) return;
      final body = jsonDecode(res.body);
      final routes = body['routes'];
      if (routes is! List || routes.isEmpty) return;
      final r = routes.first;
      final geometry = r['geometry'];
      final coords = geometry is Map ? geometry['coordinates'] : null;
      if (coords is! List) return;
      final points = coords.whereType<List>().where((x) => x.length >= 2).map((x) => LatLng((x[1] as num).toDouble(), (x[0] as num).toDouble())).toList();
      final steps = <Map<String,dynamic>>[];
      final legs = r['legs'];
      if (legs is List) for (final leg in legs) {
        final raw = leg['steps'];
        if (raw is! List) continue;
        for (final step in raw) {
          final m = step['maneuver'] is Map ? Map<String,dynamic>.from(step['maneuver']) : <String,dynamic>{};
          final type = (m['type'] ?? '').toString();
          final modifier = (m['modifier'] ?? '').toString();
          final distance = step['distance'] is num ? (step['distance'] as num).toDouble() : 0;
          if (distance < 2 && steps.isNotEmpty) continue;
          final instruction = type == 'arrive' ? 'You have arrived' : type == 'depart' ? 'Start on the current road' : type == 'roundabout' ? 'Enter the roundabout' : modifier.isEmpty ? 'Continue straight' : modifier.replaceAll('_', ' ');
          final maneuverLocation = m['location'] is List && (m['location'] as List).length >= 2
              ? LatLng(((m['location'] as List)[1] as num).toDouble(), ((m['location'] as List)[0] as num).toDouble())
              : null;
          steps.add({'instruction':instruction,'road':(step['name'] ?? '').toString(),'distance':distance,'modifier':modifier,'location':maneuverLocation});
        }
      }
      setState(() {
        _routePoints = points;
        _navSteps = steps;
        _routeDistanceMeters = r['distance'] is num ? (r['distance'] as num).toDouble() : null;
        _routeDurationSeconds = r['duration'] is num ? (r['duration'] as num).toDouble() : null;
        _activeNavIndex = 0;
        _lastRouteUpdate = DateTime.now();
      });
    } catch (_) {} finally { _routeLoading = false; }
  }
  void _fitCameraIfReady() {
    if (!_mapReady || _userMovedMap) return;
    final me = widget.isRider ? _driverLocation : _customerLocation;
    final other = widget.isRider ? _customerLocation : _driverLocation;
    if (me == null) return;
    final now = DateTime.now();
    if (_lastCameraMove != null && now.difference(_lastCameraMove!) < const Duration(milliseconds: 900)) return;
    if (other != null) {
      final meters = Geolocator.distanceBetween(me.latitude, me.longitude, other.latitude, other.longitude);
      final zoom = meters <= 30 ? 18.8 :
          meters <= 80 ? 18.2 :
          meters <= 200 ? 17.3 :
          meters <= 500 ? 16.2 :
          meters <= 1200 ? 15.2 : 14.2;
      final mid = LatLng((me.latitude + other.latitude) / 2, (me.longitude + other.longitude) / 2);
      _mapController.move(mid, zoom);
    } else {
      _mapController.move(me, 16);
    }
    _lastCameraMove = now;
    _cameraFitted = true;
  }

  Map<String,dynamic>? _currentNavStep() {
    if (_navSteps.isEmpty) return null;
    final me = widget.isRider ? _driverLocation : _customerLocation;
    if (me == null) return _navSteps.first;
    var best = _activeNavIndex.clamp(0, _navSteps.length - 1);
    for (var i = best; i < _navSteps.length; i++) {
      final loc = _navSteps[i]['location'];
      if (loc is LatLng) {
        final meters = Geolocator.distanceBetween(me.latitude, me.longitude, loc.latitude, loc.longitude);
        if (meters > 18) {
          best = i;
          break;
        }
        if (i < _navSteps.length - 1) best = i + 1;
      }
    }
    _activeNavIndex = best;
    return _navSteps[best];
  }

  Widget _circleMarker({required Color color, required IconData icon, double size = 58}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 4),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.48),
    );
  }

  List<Marker> _markers() => [
    if (_pickupLocation != null)
      Marker(point: _pickupLocation!, width: 62, height: 62, child: _circleMarker(color: Colors.green, icon: Icons.check)),
    if (_driverLocation != null)
      Marker(
        point: _driverLocation!,
        width: 62,
        height: 62,
        child: Transform.rotate(
          angle: _markerRotation * math.pi / 180,
          child: _circleMarker(color: const Color(0xFF673AB7), icon: Icons.two_wheeler),
        ),
      ),
    if (_customerLocation != null)
      Marker(point: _customerLocation!, width: 70, height: 70, child: Container(decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white, boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 7)]), padding: const EdgeInsets.all(4), child: Container(decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF1976D2)), child: const Icon(Icons.person, color: Colors.white, size: 30)))),
    if (_destinationLocation != null)
      Marker(point: _destinationLocation!, width: 62, height: 62, child: _circleMarker(color: Colors.red, icon: Icons.flag)),
  ];

  @override
  Widget build(BuildContext context) {
    final center = _pickupLocation ?? const LatLng(25.9123, 81.9876);
    return Scaffold(
      backgroundColor: const Color(0xFFF8F6F0),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF8F6F0),
        elevation: 0,
        title: const Text('Live ride tracking', style: TextStyle(color: Colors.black, fontSize: 18)),
        leading: IconButton(icon: const Icon(Icons.arrow_back, color: Colors.black), onPressed: () => Navigator.pop(context)),
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: 14.5,
              onMapReady: () {
                _mapReady = true;
                _fitCameraIfReady();
              },
              onPositionChanged: (position, hasGesture) {
                if (hasGesture) _userMovedMap = true;
              },
            ),
            children: [
              TileLayer(
                urlTemplate: _mapboxTilesUrl,
                maxZoom: 19,
                userAgentPackageName: 'com.allways.app',
              ),
              if (_routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(points: _routePoints, color: const Color(0xFF673AB7), strokeWidth: 5),
                  ],
                ),
              MarkerLayer(markers: _markers()),
            ],
          ),
          Positioned(
            top: 12, left: 16, right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFFDECEF),
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 8)],
              ),
              child: Row(
                children: [
                  Icon(Icons.circle, color: Colors.green, size: 12),
                  SizedBox(width: 8),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Live ride tracking', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    Text(widget.isRider ? 'Customer location is updating live' : 'Partner location is updating live', style: TextStyle(color: Colors.black54, fontSize: 12)),
                  ])),
                  Icon(Icons.my_location, color: Colors.black87),
                ],
              ),
            ),
          ),
          if (_navSteps.isNotEmpty && _currentNavStep() != null)
            Positioned(
              top: 84, left: 16, right: 16,
              child: Card(child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [
                Builder(builder: (context) {
                  final step = _currentNavStep()!;
                  final modifier = (step['modifier'] ?? '').toString();
                  final arrow = modifier.contains('left') ? '←' : modifier.contains('right') ? '→' : modifier.contains('uturn') ? '↶' : '↑';
                  return Container(width:48,height:48,alignment:Alignment.center,decoration:BoxDecoration(color:const Color(0xFF673AB7),borderRadius:BorderRadius.circular(14)),child:Text(arrow,style:const TextStyle(color:Colors.white,fontSize:28,fontWeight:FontWeight.w900)));
                }),
                const SizedBox(width:12),
                Expanded(child:Builder(builder:(context){
                  final step=_currentNavStep()!;
                  final meters=(step['distance'] is num ? (step['distance'] as num).toDouble() : 0);
                  return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                    Text((step['instruction']??'Continue').toString(),style:const TextStyle(fontSize:17,fontWeight:FontWeight.w900)),
                    Text((meters < 1000 ? meters.round().toString()+' m' : (meters/1000).toStringAsFixed(1)+' km') + ((step['road']??'').toString().isEmpty?'':' • '+(step['road']).toString()),style:const TextStyle(color:Colors.grey),maxLines:1,overflow:TextOverflow.ellipsis),
                  ]);
                })),
              ]))),
            ),
          Positioned(
            bottom: 20, left: 16, right: 16,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFFDECEF),
                borderRadius: BorderRadius.circular(20),
                boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10)],
              ),
              child: Row(
                children: [
                  Icon(widget.isRider ? Icons.person : Icons.two_wheeler, color: Colors.black87, size: 28),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(widget.isRider ? 'Blue person = customer • Purple bike = you' : 'Purple bike = partner • Blue person = you', style: const TextStyle(color: Colors.black87, fontSize: 13, fontWeight: FontWeight.w700)),
                    if (_distanceToOtherKm != null)
                      Text((widget.isRider ? 'Customer' : 'Partner') + ' • ' + (_distanceToOtherKm! < 1 ? (_distanceToOtherKm! * 1000).round().toString() + ' m' : _distanceToOtherKm!.toStringAsFixed(1) + ' km') + ' away • ETA ' + _etaText, style: const TextStyle(color: Colors.black54, fontSize: 13)),
                    if (!widget.isRider && _confirmationPin.length == 4 && ['accepted','arrived','started'].contains(_rideStatus.toLowerCase()))
                      Padding(
                        padding: const EdgeInsets.only(top: 7),
                        child: Text('Confirmation number: $_confirmationPin • Share with your carrier', style: const TextStyle(color: Color(0xFF8E5A73), fontSize: 13, fontWeight: FontWeight.w800)),
                      ),
                  ])),
                  TextButton(onPressed: () => _triggerPhoneCall(_contactPhone), child: const Text('Call', style: TextStyle(color: Color(0xFF8E5A73)))),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}