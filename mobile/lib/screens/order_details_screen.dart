import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../allways_design.dart';

class OrderDetailsScreen extends StatefulWidget {
  final String orderId;
  const OrderDetailsScreen({super.key, required this.orderId});
  @override State<OrderDetailsScreen> createState() => _OrderDetailsScreenState();
}

class _OrderDetailsScreenState extends State<OrderDetailsScreen> {
  final MapController _mapController = MapController();
  StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>? _trackingOrderSubscription;
  StreamSubscription<Position>? _customerLocationSubscription;
  bool _customerTrackingStarted = false;
  LatLng? _customer, _carrier, _destination;
  bool _mapReady = false, _cameraFitted = false;

  @override
  void initState() {
    super.initState();
    _watchDeliveryTracking();
  }

  @override
  void dispose() {
    _trackingOrderSubscription?.cancel();
    _customerLocationSubscription?.cancel();
    super.dispose();
  }

  Future<void> _watchDeliveryTracking() async {
    _trackingOrderSubscription = FirebaseFirestore.instance
        .collection('orders')
        .doc(widget.orderId)
        .snapshots()
        .listen((snap) async {
      final d = snap.data();
      if (d == null) return;
      final status = (d['status'] ?? '').toString().toLowerCase().replaceAll('_', ' ');
      final active = status == 'out for delivery';
      final terminal = {'delivered', 'completed', 'cancelled', 'rejected', 'expired'}.contains(status);
      if (active && !_customerTrackingStarted) {
        await _startCustomerTracking();
      } else if (terminal) {
        await _stopCustomerTracking();
      }
    });
  }

  Future<bool> _trackingDisclosure() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('allways_order_location_disclosure_shown') == true) return true;
    if (!mounted) return false;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Live delivery tracking'),
        content: const Text(
          'While your order is out for delivery, ALLways can share your live location with your assigned delivery partner so they can find you accurately. Location sharing stops when the delivery is completed or cancelled.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Continue')),
        ],
      ),
    ) ?? false;
    if (accepted) await prefs.setBool('allways_order_location_disclosure_shown', true);
    return accepted;
  }

  Future<void> _startCustomerTracking() async {
    if (_customerTrackingStarted || !mounted) return;
    if (!await _trackingDisclosure()) return;
    _customerTrackingStarted = true;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _customerTrackingStarted = false;
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        _customerTrackingStarted = false;
        return;
      }

      final LocationSettings settings = Platform.isAndroid
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
              intervalDuration: const Duration(seconds: 10),
              foregroundNotificationConfig: const ForegroundNotificationConfig(
                notificationTitle: 'ALLways delivery tracking',
                notificationText: 'ALLways is sharing your live location for your active delivery.',
                notificationChannelName: 'ALLways Delivery Tracking',
                enableWakeLock: true,
                setOngoing: true,
              ),
            )
          : const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
            );

      final first = await Geolocator.getCurrentPosition(locationSettings: settings);
      await FirebaseFirestore.instance.collection('orders').doc(widget.orderId).set({
        'customerLat': first.latitude,
        'customerLng': first.longitude,
        'customerLocationUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      _customerLocationSubscription?.cancel();
      _customerLocationSubscription = Geolocator.getPositionStream(
        locationSettings: settings,
      ).listen((position) async {
        try {
          await FirebaseFirestore.instance.collection('orders').doc(widget.orderId).set({
            'customerLat': position.latitude,
            'customerLng': position.longitude,
            'customerLocationUpdatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        } catch (_) {}
      });
    } catch (_) {
      _customerTrackingStarted = false;
    }
  }

  Future<void> _stopCustomerTracking() async {
    await _customerLocationSubscription?.cancel();
    _customerLocationSubscription = null;
    _customerTrackingStarted = false;
  }

  double? _n(dynamic v) => v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');
  LatLng? _point(Map<String,dynamic> d, List<String> prefixes) {
    for (final p in prefixes) {
      final lat = _n(d['${p}Lat'] ?? d['${p}Latitude']);
      final lng = _n(d['${p}Lng'] ?? d['${p}Longitude']);
      if (lat != null && lng != null && lat.isFinite && lng.isFinite) return LatLng(lat,lng);
    }
    return null;
  }
  String _phone(Map<String,dynamic> d) => (d['carrierPhone'] ?? d['driverPhone'] ?? d['partnerPhone'] ?? d['deliveryPhone'] ?? '').toString().trim();
  String _name(Map<String,dynamic> d) => (d['carrierName'] ?? d['driverName'] ?? d['partnerName'] ?? 'Delivery partner').toString();
  String _status(Map<String,dynamic> d) {
    final s=(d['status'] ?? 'New Order').toString().toLowerCase().replaceAll('_',' ');
    if (s=='assigned' || s=='picked up') return 'Out for delivery';
    return d['status']?.toString() ?? 'New Order';
  }
  int _statusIndex(String s) {
    const stages=['New Order','Confirmed','Preparing','Out for delivery','Delivered'];
    final i=stages.indexWhere((x)=>x.toLowerCase()==s.toLowerCase());
    return i<0 ? 0 : i;
  }
  String _placed(dynamic v) {
    DateTime? d;
    if(v is Timestamp) d=v.toDate();
    if(v is num) d=DateTime.fromMillisecondsSinceEpoch(v.toInt());
    if(d==null) return (v?.toString().trim().isNotEmpty==true ? v.toString() : 'Recent');
    final h=d.hour%12==0?12:d.hour%12;
    const m=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${m[d.month-1]} ${d.year}, ${h.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')} ${d.hour>=12?'PM':'AM'}';
  }

  void _toast(String s) { if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s))); }
  Future<void> _copy() async { await Clipboard.setData(ClipboardData(text:widget.orderId)); _toast('Order ID copied.'); }
  Future<void> _call(String phone) async {
    final p=phone.replaceAll(RegExp(r'[^0-9+]'),'');
    if(p.isEmpty){_toast('Delivery partner phone number is not available yet.');return;}
    if(!await launchUrl(Uri(scheme:'tel',path:p),mode:LaunchMode.externalApplication)) _toast('Could not open the phone app.');
  }
  Future<void> _chat(String phone) async {
    final p=phone.replaceAll(RegExp(r'[^0-9]'),'');
    if(p.isEmpty){_toast('Delivery partner phone number is not available yet.');return;}
    if(await launchUrl(Uri.parse('https://wa.me/$p'),mode:LaunchMode.externalApplication)) return;
    if(!await launchUrl(Uri(scheme:'sms',path:phone),mode:LaunchMode.externalApplication)) _toast('Could not open chat.');
  }
  void _help(Map<String,dynamic> d) {
    final phone=_phone(d);
    showModalBottomSheet(context:context,showDragHandle:true,builder:(c)=>SafeArea(child:Wrap(children:[
      const ListTile(leading:Icon(Icons.support_agent),title:Text('ALLways Help',style:TextStyle(fontWeight:FontWeight.w800)),subtitle:Text('Choose an action for this order.')),
      ListTile(leading:const Icon(Icons.phone_outlined),title:const Text('Call delivery partner'),onTap:(){Navigator.pop(c);_call(phone);}),
      ListTile(leading:const Icon(Icons.chat_bubble_outline),title:const Text('Chat with delivery partner'),onTap:(){Navigator.pop(c);_chat(phone);}),
      ListTile(leading:const Icon(Icons.copy_outlined),title:const Text('Copy order ID'),onTap:(){Navigator.pop(c);_copy();}),
    ])));
  }
  void _openMap() {
    Navigator.pushNamed(context,'/live-ride-tracking',arguments:{'rideId':widget.orderId,'isRider':false});
  }

  Widget _circle(bool done) => Container(width:34,height:34,decoration:BoxDecoration(shape:BoxShape.circle,color:done?const Color(0xFFB3134A):Colors.white,border:Border.all(color:done?const Color(0xFFB3134A):const Color(0xFFD5D7DC),width:2)),child:Icon(Icons.check,size:18,color:done?Colors.white:const Color(0xFFB5B8C0)));
  Widget _timeline(String status) {
    const stages = ['New Order','Confirmed','Preparing','Out for delivery','Delivered'];
    final idx = _statusIndex(status);
    return SizedBox(
      height: 82,
      child: Row(
        children: List.generate(stages.length, (i) {
          return Expanded(
            child: Column(
              children: [
                Row(
                  children: [
                    if (i > 0) Expanded(child: Container(height: 3, color: idx >= i ? const Color(0xFFB3134A) : const Color(0xFFE1E2E6))),
                    _circle(idx >= i),
                    if (i < stages.length - 1) Expanded(child: Container(height: 3, color: idx > i ? const Color(0xFFB3134A) : const Color(0xFFE1E2E6))),
                  ],
                ),
                const SizedBox(height: 7),
                Text(
                  stages[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10, fontWeight: i == idx ? FontWeight.w800 : FontWeight.w500, color: idx >= i ? const Color(0xFF252731) : const Color(0xFF8B8E98)),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _hero(BuildContext context, String status) {
    final cancelled=status.toLowerCase()=='cancelled';
    final dark=Theme.of(context).brightness==Brightness.dark;
    return Container(padding:const EdgeInsets.fromLTRB(22,20,18,20),decoration:BoxDecoration(gradient:LinearGradient(colors:dark?[const Color(0xFF2A1821),const Color(0xFF21151B)]:[const Color(0xFFFFF0F5),const Color(0xFFFFE7EF)]),borderRadius:BorderRadius.circular(28),boxShadow:const[BoxShadow(color:Color(0x16000000),blurRadius:18,offset:Offset(0,7))]),child:Row(children:[
      Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Container(padding:const EdgeInsets.symmetric(horizontal:14,vertical:9),decoration:BoxDecoration(color:cancelled?Colors.grey.shade700:const Color(0xFFB3134A),borderRadius:BorderRadius.circular(24)),child:Text(cancelled?'Cancelled':status,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w800,fontSize:13))),
        const SizedBox(height:17),
        Text(cancelled?'Your order was cancelled.':'Your essentials are\non the way!',style:TextStyle(fontSize:26,height:1.05,fontWeight:FontWeight.w900,color:dark?const Color(0xFFF5F5F7):const Color(0xFF161821))),
        const SizedBox(height:9),
        Text('Your order is tracked in realtime',style:TextStyle(fontSize:14,color:dark?const Color(0xFFA7A9B0):const Color(0xFF60636E))),
      ])),
      Container(width:92,height:92,decoration:BoxDecoration(color:dark?const Color(0xFF3A252E):Colors.white.withValues(alpha:.6),shape:BoxShape.circle),child:Icon(cancelled?Icons.cancel_outlined:Icons.delivery_dining,size:54,color:const Color(0xFFB3134A))),
    ]));
  }

  Widget _marker(Color color,IconData icon)=>Container(decoration:BoxDecoration(color:color,shape:BoxShape.circle,border:Border.all(color:Colors.white,width:4),boxShadow:const[BoxShadow(color:Color(0x33000000),blurRadius:7,offset:Offset(0,2))]),child:Icon(icon,color:Colors.white,size:23));

  Widget _mapCard(BuildContext context, Map<String,dynamic> d) {
    _customer = _point(d, ['customer','pickup']);
    _carrier = _point(d, ['carrier','driver','partner','owner']);
    _destination = _point(d, ['destination','delivery']);
    final dark=Theme.of(context).brightness==Brightness.dark;
    final points = <LatLng>[
      if (_customer != null) _customer!,
      if (_carrier != null) _carrier!,
      if (_destination != null) _destination!,
    ];
    if (_mapReady && !_cameraFitted && points.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_cameraFitted) return;
        try {
          if (points.length == 1) {
            _mapController.move(points.first, 15);
          } else {
            _mapController.fitCamera(CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.all(40)));
          }
          _cameraFitted = true;
        } catch (_) {}
      });
    }
    final center = _carrier ?? _customer ?? _destination ?? const LatLng(25.9123, 81.9876);
    final map = points.isEmpty
        ? Container(color: dark?const Color(0xFF202227):const Color(0xFFF2F3F5), alignment: Alignment.center, child: Text('Waiting for the rider location…',style:TextStyle(color:dark?const Color(0xFFA7A9B0):null)))
        : FlutterMap(
            mapController: _mapController,
            options: MapOptions(initialCenter: center, initialZoom: 14.5, onMapReady: () => _mapReady = true),
            children: [
              TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', maxZoom: 19, userAgentPackageName: 'com.allways.app'),
              MarkerLayer(markers: [
                if (_customer != null) Marker(point: _customer!, width: 48, height: 48, child: _marker(const Color(0xFF18A957), Icons.location_on)),
                if (_carrier != null) Marker(point: _carrier!, width: 56, height: 56, child: _marker(const Color(0xFF673AB7), Icons.two_wheeler)),
                if (_destination != null) Marker(point: _destination!, width: 48, height: 48, child: _marker(const Color(0xFFB3134A), Icons.location_on)),
              ]),
            ],
          );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(color: dark?const Color(0xFF191B20):Colors.white, borderRadius: BorderRadius.circular(28), boxShadow: const [BoxShadow(color: Color(0x12000000), blurRadius: 18, offset: Offset(0, 7))]),
      child: Column(
        children: [
          Row(children: [
            Container(width: 10, height: 10, decoration: const BoxDecoration(color: Color(0xFF18A957), shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Live Tracking', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 19,color:dark?const Color(0xFFF5F5F7):const Color(0xFF252731))),
              Text('Your rider is on the way', style: TextStyle(color:dark?const Color(0xFFA7A9B0):const Color(0xFF777B85))),
            ])),
            Icon(Icons.schedule, color: dark?const Color(0xFFE0E1E5):const Color(0xFF252A36)),
            const SizedBox(width: 5),
            Text('Live', style: TextStyle(fontWeight: FontWeight.w800,color:dark?const Color(0xFFF0F1F3):const Color(0xFF252731))),
          ]),
          const SizedBox(height: 14),
          SizedBox(height: 210, child: ClipRRect(borderRadius: BorderRadius.circular(22), child: map)),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: points.isEmpty ? null : _openMap,
              icon: const Icon(Icons.map_outlined, size: 18),
              label: const Text('View on Map'),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF252A36), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rider(BuildContext context, Map<String,dynamic> d) {
    final dark=Theme.of(context).brightness==Brightness.dark; final phone=_phone(d); final name=_name(d); final rating=(d['carrierRating']??d['driverRating']??d['partnerRating']??'').toString();
    return Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:dark?const Color(0xFF191B20):Colors.white,borderRadius:BorderRadius.circular(26),boxShadow:const[BoxShadow(color:Color(0x12000000),blurRadius:18,offset:Offset(0,7))]),child:Row(children:[
      const CircleAvatar(radius:30,backgroundColor:Color(0xFFFFE8F0),child:Icon(Icons.person,color:Color(0xFFB3134A),size:32)),
      const SizedBox(width:13),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(children:[Flexible(child:Text(name,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:17,fontWeight:FontWeight.w900))),if(rating.isNotEmpty)...[const SizedBox(width:7),const Icon(Icons.star,color:Color(0xFFFFB000),size:18),Text(' $rating',style:const TextStyle(fontWeight:FontWeight.w700))]]),
        Text('Your delivery partner',style:TextStyle(color:dark?const Color(0xFFA7A9B0):const Color(0xFF777B85))),if(phone.isNotEmpty)Text(phone,style:TextStyle(color:dark?const Color(0xFFCFD1D7):const Color(0xFF4F535D))),
      ])),
      IconButton(tooltip:'Chat',onPressed:phone.isEmpty?null:()=>_chat(phone),icon:const Icon(Icons.chat_bubble_outline,color:Color(0xFFB3134A))),
      IconButton(tooltip:'Call',onPressed:phone.isEmpty?null:()=>_call(phone),icon:const Icon(Icons.phone_outlined,color:Color(0xFFB3134A))),
    ]));
  }

  Widget _items(BuildContext context, List<dynamic> items) {
    final dark=Theme.of(context).brightness==Brightness.dark;
    return Container(padding:const EdgeInsets.fromLTRB(18,17,18,8),decoration:BoxDecoration(color:dark?const Color(0xFF191B20):Colors.white,borderRadius:BorderRadius.circular(26),boxShadow:const[BoxShadow(color:Color(0x12000000),blurRadius:18,offset:Offset(0,7))]),child:Column(children:[
    Row(children:[Text('Items in Order',style:TextStyle(fontSize:19,fontWeight:FontWeight.w900,color:dark?const Color(0xFFF5F5F7):const Color(0xFF171920))),const Spacer(),Text('${items.length} items',style:TextStyle(color:dark?const Color(0xFFA7A9B0):const Color(0xFF777B85)))]),const Divider(height:24),
    ...items.map((raw){final m=raw is Map?Map<String,dynamic>.from(raw):<String,dynamic>{};final name=(m['name']??m['title']??'Item').toString();final q=(m['quantity']??m['qty']??1) is num?(m['quantity']??m['qty']??1).toInt():1;final p=(m['price']??m['amount']??0) is num?(m['price']??m['amount']??0).toDouble():double.tryParse((m['price']??m['amount']??0).toString())??0;return Padding(padding:const EdgeInsets.only(bottom:12),child:Row(children:[Container(width:66,height:66,decoration:BoxDecoration(color:dark?const Color(0xFF2A2025):const Color(0xFFF7F0F3),borderRadius:BorderRadius.circular(15)),child:const Icon(Icons.shopping_bag_outlined,color:Color(0xFFB3134A),size:30)),const SizedBox(width:13),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(name,style:TextStyle(fontSize:16,fontWeight:FontWeight.w800,color:dark?const Color(0xFFF0F1F3):const Color(0xFF171920))),Text('$q × ₹${p.toStringAsFixed(p%1==0?0:2)}',style:const TextStyle(color:Color(0xFF777B85)))])),Text('₹${(p*q).toStringAsFixed(p*q%1==0?0:2)}',style:TextStyle(fontSize:16,fontWeight:FontWeight.w900,color:dark?const Color(0xFFF0F1F3):const Color(0xFF171920)))]));}),
  ]));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).brightness==Brightness.dark?const Color(0xFF121014):AllwaysColors.background,
      appBar: AppBar(
        backgroundColor: Theme.of(context).brightness==Brightness.dark?const Color(0xFF121014):AllwaysColors.background,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Back',
          icon: Icon(Icons.arrow_back, color: Theme.of(context).brightness==Brightness.dark?const Color(0xFFF5F5F7):const Color(0xFF171920), size: 30),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Order Details', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900, color: Theme.of(context).brightness==Brightness.dark?const Color(0xFFF5F5F7):const Color(0xFF171920))),
        actions: [
          TextButton.icon(
            onPressed: () async {
              final s = await FirebaseFirestore.instance.collection('orders').doc(widget.orderId).get();
              if (s.exists && s.data() != null) _help(s.data()!);
            },
            icon: const Icon(Icons.headset_mic_outlined, size: 18, color: AllwaysColors.primary),
            label: const Text('Help', style: TextStyle(color: AllwaysColors.primary, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('orders').doc(widget.orderId).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Could not load this order.\\n${snapshot.error}', textAlign: TextAlign.center));
          }
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          if (!snapshot.data!.exists) return const Center(child: Text('This order could not be found.'));
          final d = snapshot.data!.data()!;
          final status = _status(d);
          final items = (d['items'] as List<dynamic>?) ?? const [];
          final total = d['totalAmount'] ?? d['total'] ?? 0;
          final phone = _phone(d);
          final hasCarrier = _point(d, ['carrier','driver','partner']) != null;
          final normalizedStatus = status.toLowerCase();
          final terminalDelivery = normalizedStatus == 'delivered' || normalizedStatus == 'completed' || normalizedStatus == 'cancelled' || normalizedStatus == 'rejected' || normalizedStatus == 'expired';
          final showTracking = !terminalDelivery && (normalizedStatus == 'out for delivery' || normalizedStatus == 'assigned' || hasCarrier);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              Row(
                children: [
                  Expanded(child: Text('Order #${widget.orderId}', overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Theme.of(context).brightness==Brightness.dark?const Color(0xFFF5F5F7):const Color(0xFF171920)))),
                  IconButton(tooltip: 'Copy order ID', onPressed: _copy, icon: const Icon(Icons.copy_outlined, size: 19)),
                ],
              ),
              Text('Placed on ${_placed(d['placedAt'] ?? d['createdAt'])}', style: TextStyle(fontSize: 14, color: Theme.of(context).brightness==Brightness.dark?const Color(0xFFA7A9B0):const Color(0xFF777B85))),
              const SizedBox(height: 16),
              _hero(context, status),
              const SizedBox(height: 22),
              _timeline(status),
              if (showTracking) ...[
                const SizedBox(height: 8),
                _mapCard(context, d),
              ],
              if (hasCarrier || phone.isNotEmpty) ...[
                const SizedBox(height: 14),
                _rider(context, d),
              ],
              const SizedBox(height: 18),
              _items(context, items),
              const SizedBox(height: 14),
              InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () {
                  showModalBottomSheet(
                    context: context,
                    showDragHandle: true,
                    builder: (c) => SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(22, 8, 22, 28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Payment details', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                            const SizedBox(height: 14),
                            const ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.payments_outlined, color: Color(0xFFB3134A)),
                              title: Text('Payment method'),
                              subtitle: Text('Cash on Delivery'),
                            ),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.receipt_long_outlined, color: Color(0xFFB3134A)),
                              title: const Text('Order total'),
                              trailing: Text('₹$total', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                  decoration: BoxDecoration(color: Theme.of(context).brightness==Brightness.dark?const Color(0xFF2A1821):const Color(0xFFFFEFF4), borderRadius: BorderRadius.circular(24)),
                  child: Row(
                    children: [
                      const Icon(Icons.account_balance_wallet_outlined, color: Color(0xFFB3134A)),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Order Total', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                            SizedBox(height: 4),
                            Text('Cash on Delivery', style: TextStyle(color: Color(0xFF777B85))),
                          ],
                        ),
                      ),
                      Text('₹$total', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900,color: Theme.of(context).brightness==Brightness.dark?const Color(0xFFF0F1F3):const Color(0xFF171920))),
                      const Icon(Icons.keyboard_arrow_down, color: Color(0xFFB3134A)),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
