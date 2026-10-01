import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:share_plus/share_plus.dart';
import 'package:image_picker/image_picker.dart';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'firebase_options.dart';
import 'utils/voice_search_helper.dart';
import 'screens/live_ride_tracking_screen.dart';
import 'screens/notifications_settings_screen.dart';
import 'screens/wishlist_screen.dart';
import 'screens/order_details_screen.dart';
import 'allways_design.dart';

const cloudinaryCloudName='busdtvia';
const cloudinaryUploadPreset='allways_preset';

String cloudinaryImageUrl(String url, {required double width, required double height}) {
  final value = url.trim();
  if (value.isEmpty || !value.contains('res.cloudinary.com/')) return value;
  final safeW = width.isFinite && width > 0 ? width.round() : 1;
  final safeH = height.isFinite && height > 0 ? height.round() : 1;
  final uploadMarker = '/image/upload/';
  final markerIndex = value.indexOf(uploadMarker);
  if (markerIndex < 0) return value;
  final transform = 'w_$safeW,h_$safeH,c_fill,g_auto,f_auto,q_auto,e_sharpen:100';
  final after = markerIndex + uploadMarker.length;
  // Avoid stacking another ALLways-generated transformation if the URL was
  // already formatted for a previous display container.
  var rest = value.substring(after);
  if (rest.contains('/')) {
    final firstSegment = rest.substring(0, rest.indexOf('/'));
    final isTransformation = firstSegment.contains('w_') || firstSegment.contains('h_') ||
        firstSegment.contains('c_fill') || firstSegment.contains('g_auto') ||
        firstSegment.contains('f_auto') || firstSegment.contains('q_auto');
    if (isTransformation) rest = rest.substring(rest.indexOf('/') + 1);
  }
  return value.substring(0, after) + transform + '/' + rest;
}

String cloudinarySmartCropUrl(String url) {
  final value = url.trim();
  if (value.isEmpty || !value.contains('res.cloudinary.com/')) return value;
  const uploadMarker = '/image/upload/';
  final markerIndex = value.indexOf(uploadMarker);
  if (markerIndex < 0) return value;
  final after = markerIndex + uploadMarker.length;
  final rest = value.substring(after);
  if (rest.startsWith('c_fill,g_auto/')) return value;
  return value.substring(0, after) + 'c_fill,g_auto/' + rest;
}

Future<String> uploadImageToCloudinary(XFile image, {String? folder}) async {
  if (cloudinaryCloudName.isEmpty || cloudinaryUploadPreset.isEmpty) {
    throw Exception('Cloudinary is not configured. Set cloudinaryCloudName and cloudinaryUploadPreset.');
  }

  final endpoint = Uri.parse(
    'https://api.cloudinary.com/v1_1/' + cloudinaryCloudName + '/image/upload',
  );
  final request = http.MultipartRequest('POST', endpoint);
  request.fields['upload_preset'] = cloudinaryUploadPreset;
  if (folder != null && folder.isNotEmpty) {
    request.fields['folder'] = folder;
  }
  request.files.add(await http.MultipartFile.fromPath('file', image.path));

  final response = await request.send();
  final body = await response.stream.bytesToString();

  Map<String, dynamic> data = {};
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      data = Map<String, dynamic>.from(decoded);
    }
  } catch (_) {}

  if (response.statusCode < 200 || response.statusCode >= 300) {
    final error = data['error'];
    final message = error is Map
        ? (error['message'] ?? 'Unknown Cloudinary error').toString()
        : body;
    throw Exception('Cloudinary upload failed [HTTP ${response.statusCode}]: $message');
  }

  final secureUrl = (data['secure_url'] ?? '').toString();
  if (secureUrl.isEmpty) {
    throw Exception('Cloudinary upload succeeded but no secure_url was returned.');
  }
  return secureUrl;
}
const shareApkUrl='https://github.com/mauryasujeet698-svg/Always-website/releases/download/allways-latest/allways-v1.5.0.apk';

const inventoryEndpoint='https://script.google.com/macros/s/AKfycbxnmGS7Q6t7PpPWiT50V87JmA0Qbh2tSi1UKLFzN28dQpybjw7vvCufnryi-qpTnq0b0IA/exec';
const updateManifestUrl='https://raw.githubusercontent.com/mauryasujeet698-svg/Always-website/allways-android-app/mobile/update.json';

const Map<String,dynamic> _defaultDeliverySettings = {
  'deliveryEnabled': true,
  'instantEnabled': true,
  'scheduledEnabled': true,
  'freeScheduledThreshold': 499,
  'scheduledPerKm': 11,
  'instantBaseFee': 35,
  'instantPerKm': 11,
  'scheduledCutoffHour': 13,
  'scheduledCutoffMinute': 30,
  'pilotRadiusKm': 4,
  'pilotCenterLat': 0,
  'pilotCenterLng': 0,
  'specialOfferEnabled': false,
  'specialOfferTitle': 'Just for you',
  'specialOfferMessage': 'More scheduled delivery slots are available today.',
};

num deliveryNum(Map<String,dynamic> s,String key,num fallback){
  final v=s[key];
  if(v is num)return v;
  return num.tryParse((v??'').toString())??fallback;
}

bool deliveryBool(Map<String,dynamic> s,String key,bool fallback){
  final v=s[key];
  if(v is bool)return v;
  return (v??fallback).toString().toLowerCase()=='true';
}

DateTime scheduledCutoffNow(Map<String,dynamic> s){
  final now=DateTime.now();
  final h=deliveryNum(s,'scheduledCutoffHour',13).toInt().clamp(0,23);
  final m=deliveryNum(s,'scheduledCutoffMinute',30).toInt().clamp(0,59);
  return DateTime(now.year,now.month,now.day,h,m);
}

int chargeableKm(double distanceKm){
  if(distanceKm<=0)return 0;
  return math.max(1,distanceKm.ceil());
}

Future<Map<String,dynamic>> loadDeliverySettings() async {
  try{
    final snap=await FirebaseFirestore.instance.collection('settings').doc('delivery').get();
    final data=snap.data();
    if(data!=null)return {..._defaultDeliverySettings,...data};
  }catch(_){}
  return {..._defaultDeliverySettings};
}


final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);
final ValueNotifier<bool> unreadNotificationNotifier = ValueNotifier(false);
final ValueNotifier<String> languageNotifier = ValueNotifier('English');

const Map<String,Map<String,String>> _translations = {
  'Hindi': {
    'Shop':'दुकान','Travel':'यात्रा','Profile':'प्रोफ़ाइल','Notifications':'सूचनाएँ','Appearance':'दिखावट','Language':'भाषा','Share ALLways':'ALLways साझा करें','Check for Updates':'अपडेट जाँचें','Log Out':'लॉग आउट','Book vehicle':'वाहन बुक करें','Book a ride partner':'राइड पार्टनर बुक करें','Search products':'उत्पाद खोजें','Orders':'ऑर्डर','Cart':'कार्ट','Add to cart':'कार्ट में जोड़ें','New Order':'नया ऑर्डर','Confirmed':'पुष्टि','Preparing':'तैयारी में','Out for delivery':'डिलीवरी के लिए रवाना','Delivered':'डिलीवर हो गया','Cancelled':'रद्द','Save changes':'बदलाव सहेजें','Close':'बंद करें','Your name':'आपका नाम',
  },
  'Hinglish': {
    'Shop':'Shop','Travel':'Travel','Profile':'Profile','Notifications':'Notifications','Appearance':'Appearance','Language':'Language','Share ALLways':'ALLways Share Karein','Check for Updates':'Update Check Karein','Log Out':'Logout','Book vehicle':'Vehicle Book Karein','Book a ride partner':'Ride Partner Book Karein','Search products':'Products Search Karein','Orders':'Orders','Cart':'Cart','Add to cart':'Cart mein add karein','New Order':'Naya Order','Confirmed':'Confirmed','Preparing':'Preparing','Out for delivery':'Delivery ke liye nikla','Delivered':'Delivered','Cancelled':'Cancelled','Save changes':'Changes Save Karein','Close':'Close','Your name':'Aapka naam',
  },
  'Bhojpuri': {
    'Shop':'दुकान','Travel':'यात्रा','Profile':'प्रोफाइल','Notifications':'सूचना','Appearance':'दिखावट','Language':'भाषा','Share ALLways':'ALLways साझा करीं','Check for Updates':'अपडेट देखीं','Log Out':'लॉग आउट','Book vehicle':'गाड़ी बुक करीं','Book a ride partner':'राइड पार्टनर बुक करीं','Search products':'सामान खोजीं','Orders':'ऑर्डर','Cart':'कार्ट','Add to cart':'कार्ट में डालीं','New Order':'नया ऑर्डर','Confirmed':'पक्का','Preparing':'तैयार हो रहल','Out for delivery':'डिलीवरी खातिर निकलल','Delivered':'पहुंच गइल','Cancelled':'रद्द','Save changes':'बदलाव सेव करीं','Close':'बंद करीं','Your name':'रउरा के नाम',
  },
  'Awadhi': {
    'Shop':'दुकान','Travel':'यात्रा','Profile':'प्रोफाइल','Notifications':'सूचना','Appearance':'दिखावट','Language':'भाषा','Share ALLways':'ALLways साझा करौ','Check for Updates':'अपडेट देखौ','Log Out':'लॉग आउट','Book vehicle':'गाड़ी बुक करौ','Book a ride partner':'राइड पार्टनर बुक करौ','Search products':'सामान खोजौ','Orders':'ऑर्डर','Cart':'कार्ट','Add to cart':'कार्ट मा डालौ','New Order':'नवा ऑर्डर','Confirmed':'पक्का','Preparing':'तैयार होत','Out for delivery':'डिलीवरी खातिर निकर गवा','Delivered':'पहुंच गवा','Cancelled':'रद्द','Save changes':'बदलाव सेव करौ','Close':'बंद करौ','Your name':'आपका नाउँ',
  },
};

String tr(String key) => _translations[languageNotifier.value]?[key] ?? key;

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Notification messages are displayed by Android when the app is backgrounded
  // or terminated. Keep this handler top-level for Flutter's background isolate.
  print('ALLways background FCM: ${message.messageId}');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  final prefs = await SharedPreferences.getInstance();
  final savedNotifications = prefs.getStringList('allways_notifications') ?? <String>[];
  unreadNotificationNotifier.value = savedNotifications.isNotEmpty;
  final savedLanguage = prefs.getString('allways_language') ?? 'English';
  languageNotifier.value = _translations.containsKey(savedLanguage) ? savedLanguage : 'English';
  final savedTheme = prefs.getString('allways_theme_mode');
  if (savedTheme == 'light') {
    themeNotifier.value = ThemeMode.light;
  } else if (savedTheme == 'dark') {
    themeNotifier.value = ThemeMode.dark;
  } else {
    themeNotifier.value = ThemeMode.system;
  }
  runApp(const AllwaysApp());
}

class AllwaysApp extends StatelessWidget {
  const AllwaysApp({super.key});
  Widget build(BuildContext c)=>ValueListenableBuilder<ThemeMode>(
    valueListenable:themeNotifier,
    builder:(context,mode,_)=>
      MaterialApp(
        debugShowCheckedModeBanner:false,
        title:'ALLways',
        theme:ThemeData(
          useMaterial3:true,
          scaffoldBackgroundColor:AllwaysColors.background,
          colorScheme:ColorScheme.fromSeed(
            seedColor:AllwaysColors.primary,
            brightness:Brightness.light,
          ),
          textTheme:GoogleFonts.poppinsTextTheme().apply(
            bodyColor:AllwaysColors.text,
            displayColor:AllwaysColors.text,
          ),
          appBarTheme:const AppBarTheme(
            backgroundColor:AllwaysColors.background,
            foregroundColor:AllwaysColors.text,
            elevation:0,
            centerTitle:false,
          ),
          cardTheme:const CardThemeData(
            color:AllwaysColors.surface,
            elevation:0,
            margin:EdgeInsets.zero,
          ),
          inputDecorationTheme:InputDecorationTheme(
            filled:true,
            fillColor:Colors.white,
            border:OutlineInputBorder(
              borderRadius:BorderRadius.all(Radius.circular(16)),
              borderSide:BorderSide(color:AllwaysColors.border),
            ),
            enabledBorder:OutlineInputBorder(
              borderRadius:BorderRadius.all(Radius.circular(16)),
              borderSide:BorderSide(color:AllwaysColors.border),
            ),
            focusedBorder:const OutlineInputBorder(
              borderRadius:BorderRadius.all(Radius.circular(16)),
              borderSide:BorderSide(color:AllwaysColors.primary,width:1.5),
            ),
          ),
        ),
        darkTheme:ThemeData(
          useMaterial3:true,
          scaffoldBackgroundColor:const Color(0xFF111015),
          colorScheme:ColorScheme.fromSeed(
            seedColor:AllwaysColors.primary,
            brightness:Brightness.dark,
          ).copyWith(
            primary:AllwaysColors.primary,
            onPrimary:Colors.white,
            secondary:AllwaysColors.amber,
            onSecondary:Colors.black,
            surface:const Color(0xFF19171C),
            onSurface:const Color(0xFFF8F5F8),
            surfaceContainerLowest:const Color(0xFF111015),
            surfaceContainerLow:const Color(0xFF17151A),
            surfaceContainer:const Color(0xFF1D1A20),
            surfaceContainerHigh:const Color(0xFF252128),
            surfaceContainerHighest:const Color(0xFF2D2830),
            onSurfaceVariant:const Color(0xFFD1CAD2),
            outline:const Color(0xFF514A54),
            outlineVariant:const Color(0xFF3B353E),
            inverseSurface:const Color(0xFFF8F5F8),
            onInverseSurface:const Color(0xFF17151A),
            inversePrimary:const Color(0xFF7E003B),
          ),
          textTheme:GoogleFonts.poppinsTextTheme(ThemeData.dark().textTheme).apply(
            bodyColor:const Color(0xFFF8F5F8),
            displayColor:const Color(0xFFF8F5F8),
          ),
          appBarTheme:const AppBarTheme(
            backgroundColor:Color(0xFF111015),
            foregroundColor:Color(0xFFF8F5F8),
            elevation:0,
          ),
          cardTheme:const CardThemeData(
            color:Color(0xFF1D1A20),
            elevation:0,
            margin:EdgeInsets.zero,
          ),
          inputDecorationTheme:const InputDecorationTheme(
            filled:true,
            fillColor:Color(0xFF252128),
            hintStyle:TextStyle(color:Color(0xFFAAA2AD)),
            prefixIconColor:Color(0xFFD1CAD2),
            suffixIconColor:Color(0xFFD1CAD2),
            border:OutlineInputBorder(
              borderRadius:BorderRadius.all(Radius.circular(16)),
              borderSide:BorderSide(color:Color(0xFF514A54)),
            ),
            enabledBorder:OutlineInputBorder(
              borderRadius:BorderRadius.all(Radius.circular(16)),
              borderSide:BorderSide(color:Color(0xFF514A54)),
            ),
            focusedBorder:OutlineInputBorder(
              borderRadius:BorderRadius.all(Radius.circular(16)),
              borderSide:BorderSide(color:AllwaysColors.primary,width:1.5),
            ),
          ),
        ),
        themeMode:mode,
        home:const Shell(),
        onGenerateRoute: (settings) {
          switch (settings.name) {
            case '/live-ride-tracking':
              final args = settings.arguments;
              final rideId = args is String
                  ? args
                  : args is Map ? (args['rideId'] ?? '').toString() : '';
              final isRider = args is Map && args['isRider'] == true;
              if (rideId.isEmpty) {
                return MaterialPageRoute(
                  builder: (_) => const Scaffold(
                    body: Center(child: Text('Ride ID is required.')),
                  ),
                );
              }
              return MaterialPageRoute(
                builder: (_) => LiveRideTrackingScreen(
                  rideId: rideId,
                  isRider: isRider,
                ),
              );
            case '/notifications-settings':
              return MaterialPageRoute(
                builder: (_) => const NotificationsSettingsScreen(),
              );
            case '/wishlist':
              return MaterialPageRoute(
                builder: (_) => const WishlistPage(),
              );
            case '/order-details':
              final args = settings.arguments;
              final orderId = args is String
                  ? args
                  : args is Map ? (args['orderId'] ?? '').toString() : '';
              if (orderId.isEmpty) {
                return MaterialPageRoute(
                  builder: (_) => const Scaffold(
                    body: Center(child: Text('Order ID is required.')),
                  ),
                );
              }
              return MaterialPageRoute(
                builder: (_) => OrderDetailsScreen(orderId: orderId),
              );
            default:
              return null;
          }
        },
      ),
  );
}


Future<bool> ensureBackgroundLocationDisclosure(BuildContext context) async {
  final prefs=await SharedPreferences.getInstance();
  if(prefs.getBool('allways_background_location_disclosure_shown')==true)return true;
  if(!context.mounted)return false;
  final accepted=await showDialog<bool>(
    context:context,
    barrierDismissible:false,
    builder:(dialogContext)=>AlertDialog(
      title:const Text('Live location sharing'),
      content:const Text('ALLways collects location data to enable live delivery tracking, ride-partner tracking and vehicle-booking tracking even when the app is closed or not in use. Your location is shared only for an active trip or delivery with the authorized participant(s) and ALLways administrators for fulfillment and safety.'),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(dialogContext,false),child:const Text('Not now')),
        FilledButton(onPressed:()=>Navigator.pop(dialogContext,true),child:const Text('Continue')),
      ],
    ),
  )??false;
  if(accepted)await prefs.setBool('allways_background_location_disclosure_shown',true);
  return accepted;
}

class LiveLocationBroadcaster {
  StreamSubscription<Position>? _subscription;
  Future<bool> start({required String collection,required String docId,required String prefix,bool background=false}) async {
    await stop();
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return false;
      if(background && permission==LocationPermission.whileInUse){
        final upgraded=await Geolocator.requestPermission();
        if(upgraded!=LocationPermission.always && upgraded!=LocationPermission.whileInUse)return false;
        permission=upgraded;
      }
      final LocationSettings settings = background && Platform.isAndroid
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
              intervalDuration: const Duration(seconds: 10),
              foregroundNotificationConfig: const ForegroundNotificationConfig(
                notificationTitle: 'ALLways live tracking',
                notificationText: 'ALLways is sharing your location for an active delivery or ride.',
                notificationChannelName: 'ALLways Live Tracking',
                enableWakeLock: true,
                setOngoing: true,
              ),
            )
          : const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10);
      _subscription = Geolocator.getPositionStream(locationSettings: settings).listen((position) async {
        try {
          await FirebaseFirestore.instance.collection(collection).doc(docId).set({
            '${prefix}Lat': position.latitude,
            '${prefix}Lng': position.longitude,
            '${prefix}LocationUpdatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        } catch (_) {}
      });
      return true;
    } catch (_) { return false; }
  }
  Future<void> stop() async { await _subscription?.cancel(); _subscription=null; }
}
class _OrderSuccessScreen extends StatefulWidget {
  final String orderId;
  final VoidCallback onContinueShopping;
  final VoidCallback onTrackOrder;
  final Future<void> Function() onEnableNotifications;
  const _OrderSuccessScreen({
    required this.orderId,
    required this.onContinueShopping,
    required this.onTrackOrder,
    required this.onEnableNotifications,
  });
  @override State<_OrderSuccessScreen> createState() => _OrderSuccessScreenState();
}

class _OrderSuccessScreenState extends State<_OrderSuccessScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..forward();
  @override void dispose(){_controller.dispose();super.dispose();}

  Widget _confetti() {
    const pieces = [
      ['🎉', 0.08, 0.10], ['✨', 0.23, 0.17], ['🎊', 0.78, 0.11], ['⭐', 0.91, 0.25],
      ['💗', 0.12, 0.36], ['✨', 0.88, 0.42], ['🎈', 0.28, 0.30], ['🎉', 0.70, 0.33],
    ];
    return IgnorePointer(child: Stack(children: [
      for (final p in pieces)
        Positioned(left: MediaQuery.sizeOf(context).width * (p[1] as double), top: MediaQuery.sizeOf(context).height * (p[2] as double),
          child: Text(p[0] as String, style: TextStyle(fontSize: (p[0] == '✨' ? 22 : 28)))),
    ]));
  }

  @override Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF6F8),
      body: Stack(children: [
        Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter,end: Alignment.bottomCenter,
            colors: const [Color(0xFFFFE8EF), Color(0xFFFFF9FA), Color(0xFFFFFFFF)]),
        ))),
        _confetti(),
        SafeArea(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(24, 28, 24, 30), child: FadeTransition(
          opacity: CurvedAnimation(parent: _controller, curve: Curves.easeOut),
          child: ScaleTransition(scale: Tween<double>(begin:.92,end:1).animate(CurvedAnimation(parent:_controller,curve:Curves.easeOutBack)),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(width:118,height:118,decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(begin: Alignment.topLeft,end: Alignment.bottomRight,colors:[Color(0xFFB3134A),Color(0xFFE44D78)]),
                boxShadow: const [BoxShadow(color: Color(0x3DB3134A), blurRadius: 28, spreadRadius: 3)],
              ),child: const Icon(Icons.check_rounded,color:Colors.white,size:72)),
              const SizedBox(height:25),
              const Text('🎉 Thank you for your order!',textAlign:TextAlign.center,style:TextStyle(fontSize:31,height:1.05,fontWeight:FontWeight.w900,color:Color(0xFF191A20))),
              const SizedBox(height:12),
              const Text('ALLways is on it.',textAlign:TextAlign.center,style:TextStyle(fontSize:18,fontWeight:FontWeight.w800,color:Color(0xFFB3134A))),
              const SizedBox(height:10),
              Text('Your order #${widget.orderId} has been placed successfully.',textAlign:TextAlign.center,style:const TextStyle(fontSize:15,height:1.45,color:Color(0xFF62656E))),
              const SizedBox(height:8),
              const Text('We’ll keep you updated as your order moves from confirmed to delivered.',textAlign:TextAlign.center,style:TextStyle(fontSize:14,height:1.4,color:Color(0xFF7A7D86))),
              const SizedBox(height:25),
              Container(width:double.infinity,padding:const EdgeInsets.all(17),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(22),boxShadow:const[BoxShadow(color:Color(0x12000000),blurRadius:18,offset:Offset(0,7))]),child:const Row(children:[
                CircleAvatar(radius:22,backgroundColor:Color(0xFFFFE8EF),child:Icon(Icons.notifications_active_outlined,color:Color(0xFFB3134A))),
                SizedBox(width:13),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Text('Order updates',style:TextStyle(fontWeight:FontWeight.w900,fontSize:16)),
                  SizedBox(height:3),Text('Get notified when your order status changes.',style:TextStyle(color:Color(0xFF747780),fontSize:13)),
                ])),
              ])),
              const SizedBox(height:22),
              SizedBox(width:double.infinity,height:54,child:FilledButton.icon(
                onPressed:() async { await widget.onEnableNotifications(); },
                icon:const Icon(Icons.notifications_active_outlined),
                label:const Text('Enable notifications',style:TextStyle(fontWeight:FontWeight.w800,fontSize:16)),
                style:FilledButton.styleFrom(backgroundColor:const Color(0xFFB3134A),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(17))),
              )),
              const SizedBox(height:12),
              SizedBox(width:double.infinity,height:54,child:OutlinedButton.icon(
                onPressed:widget.onTrackOrder,icon:const Icon(Icons.local_shipping_outlined),label:const Text('Track this order',style:TextStyle(fontWeight:FontWeight.w800,fontSize:16)),
                style:OutlinedButton.styleFrom(foregroundColor:const Color(0xFFB3134A),side:const BorderSide(color:Color(0xFFB3134A)),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(17))),
              )),
              const SizedBox(height:10),
              TextButton(onPressed:widget.onContinueShopping,child:const Text('Continue shopping',style:TextStyle(fontSize:15,fontWeight:FontWeight.w800,color:Color(0xFF5D6069)))),
              const SizedBox(height:5),
              Text('Cash on Delivery • Order ID: ${widget.orderId}',textAlign:TextAlign.center,style:const TextStyle(fontSize:12,color:Color(0xFF92949C))),
            ]),
          ),
        )))),
      ]),
    );
  }
}

class LatLngTween extends Tween<LatLng> {
  LatLngTween({super.begin, super.end});
  @override LatLng lerp(double t) {
    final a=begin??end??const LatLng(0,0), b=end??a;
    return LatLng(a.latitude+(b.latitude-a.latitude)*t,a.longitude+(b.longitude-a.longitude)*t);
  }
}
Future<void> _callNumber(BuildContext context,String phone) async {
  final clean=phone.replaceAll(RegExp(r'[^0-9+]'),'');
  if(clean.isEmpty){
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Phone number is not available yet.')));
    return;
  }
  try{
    final uri=Uri(scheme:'tel',path:clean);
    if(!await launchUrl(uri,mode:LaunchMode.externalApplication)&&context.mounted){
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Could not open the phone app.')));
    }
  }catch(e){
    if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Could not place call: '+e.toString())));
  }
}

class LiveTrackingScreen extends StatefulWidget {
  final String collection,docId,title,mode;
  final String? broadcastPrefix;
  final bool readOnly;
  final bool allowCancel;
  const LiveTrackingScreen({super.key,required this.collection,required this.docId,required this.title,required this.mode,this.broadcastPrefix,this.readOnly=false,this.allowCancel=false});
  @override State<LiveTrackingScreen> createState()=>_LiveTrackingScreenState();
}

class _LiveTrackingScreenState extends State<LiveTrackingScreen> {
  final LiveLocationBroadcaster _broadcaster=LiveLocationBroadcaster();
  final MapController _mapController=MapController();
  bool _cameraFitted=false;
  bool _mapReady=false;
  List<LatLng> _routePoints=const[];
  DateTime? _lastRouteUpdate;
  bool _routeLoading=false;
  double? _liveDistanceMeters;
  double? _routeDistanceMeters;
  double? _routeDurationSeconds;

  @override void initState(){
    super.initState();
    if(!widget.readOnly&&widget.broadcastPrefix!=null){
      WidgetsBinding.instance.addPostFrameCallback((_){_startBroadcastWithDisclosure();});
    }
  }

  Future<void> _startBroadcastWithDisclosure() async {
    if(!mounted||widget.broadcastPrefix==null||widget.readOnly)return;
    final needsBackground=widget.broadcastPrefix=='partner'||widget.broadcastPrefix=='driver'||widget.broadcastPrefix=='carrier';
    if(needsBackground){
      final allowed=await ensureBackgroundLocationDisclosure(context);
      if(!allowed||!mounted)return;
    }
    await _broadcaster.start(collection:widget.collection,docId:widget.docId,prefix:widget.broadcastPrefix!,background:needsBackground);
  }

  @override void dispose(){_broadcaster.stop();_mapController.dispose();super.dispose();}

  double? _n(dynamic v)=>v is num?v.toDouble():double.tryParse(v?.toString()??'');

  LatLng? _point(Map<String,dynamic> d,String p){
    final lat=_n(d['${p}Lat']??d['${p}Latitude']);
    final lng=_n(d['${p}Lng']??d['${p}Longitude']);
    if(lat==null||lng==null||lat.isNaN||lng.isNaN)return null;
    return LatLng(lat,lng);
  }

  Future<void> _loadOSRMRoute(LatLng start,LatLng end) async {
    if(_routeLoading)return;
    _routeLoading=true;
    try{
      final url=Uri.parse('https://router.project-osrm.org/route/v1/driving/\${start.longitude},\${start.latitude};\${end.longitude},\${end.latitude}?overview=full&geometries=geojson&steps=true');
      final res=await http.get(url);if(res.statusCode!=200)return;
      final decoded=jsonDecode(res.body),routes=decoded['routes'];if(routes is! List||routes.isEmpty)return;
      final r=routes.first,coords=r['geometry']?['coordinates'];if(coords is! List)return;
      final points=coords.whereType<List>().where((x)=>x.length>=2).map((x)=>LatLng((x[1] as num).toDouble(),(x[0] as num).toDouble())).toList();
      if(!mounted)return;
      setState(()=>{_routePoints=points,_routeDistanceMeters=r['distance'] is num?(r['distance'] as num).toDouble():null,_routeDurationSeconds=r['duration'] is num?(r['duration'] as num).toDouble():null,_lastRouteUpdate=DateTime.now()});
    }catch(_){}finally{_routeLoading=false;}
  }
  void _fitCamera(List<LatLng> points) {
    if(!_mapReady)return;
    final all=<LatLng>[...points,..._routePoints];
    if(all.isEmpty)return;
    if(all.length==1){_mapController.move(all.first,15);return;}
    if(_cameraFitted)return;
    try{
      _mapController.fitCamera(CameraFit.coordinates(coordinates:all,padding:const EdgeInsets.all(70)));
      _cameraFitted=true;
    }catch(_){
      _mapController.move(all.first,14);
    }
  }

  Widget _markerCircle({required Color color,required IconData icon,double size=54,double angle=0}){
    return Transform.rotate(
      angle:angle,
      child:Container(
        width:size,height:size,
        decoration:BoxDecoration(
          color:color,
          shape:BoxShape.circle,
          border:Border.all(color:Colors.white,width:4),
          boxShadow:const[BoxShadow(color:Colors.black26,blurRadius:6,offset:Offset(0,2))],
        ),
        child:Icon(icon,color:Colors.white,size:size*.48),
      ),
    );
  }

  List<Marker> _markers({LatLng? customer,LatLng? partner,LatLng? pickup,LatLng? destination}){
    return[
      if(pickup!=null)Marker(point:pickup,width:60,height:60,child:_markerCircle(color:Colors.green,icon:Icons.check)),
      if(partner!=null)Marker(point:partner,width:60,height:60,child:_markerCircle(color:const Color(0xFF673AB7),icon:Icons.two_wheeler)),
      if(destination!=null)Marker(point:destination,width:60,height:60,child:_markerCircle(color:Colors.red,icon:Icons.flag)),
      if(customer!=null&&pickup==null)Marker(point:customer,width:56,height:56,child:_markerCircle(color:Colors.blue,icon:Icons.person,size:50)),
    ];
  }

  Future<void> _call(BuildContext context,String phone) async {
    final clean=phone.replaceAll(RegExp(r'[^0-9+]'),'');
    if(clean.isEmpty){
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Phone number is not available yet.')));
      return;
    }
    final uri=Uri(scheme:'tel',path:clean);
    try{
      if(!await launchUrl(uri,mode:LaunchMode.externalApplication)&&context.mounted){
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Could not open the phone app.')));
      }
    }catch(e){
      if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Could not place call: '+e.toString())));
    }
  }

  Future<void> _cancelActiveTrip() async {
    final user=FirebaseAuth.instance.currentUser;
    if(user==null)return;
    final ref=FirebaseFirestore.instance.collection(widget.collection).doc(widget.docId);
    final reason=await showDialog<String>(context:context,builder:(c)=>SimpleDialog(title:const Text('Cancel ride'),children:[
      SimpleDialogOption(onPressed:()=>Navigator.pop(c,'Waiting too long'),child:const Text('Waiting too long')),
      SimpleDialogOption(onPressed:()=>Navigator.pop(c,'Partner/customer not responding'),child:const Text('Not responding')),
      SimpleDialogOption(onPressed:()=>Navigator.pop(c,'Changed my mind'),child:const Text('Changed my mind')),
      SimpleDialogOption(onPressed:()=>Navigator.pop(c,'Other'),child:const Text('Other')),
    ]));
    if(reason==null)return;
    try{
      await FirebaseFirestore.instance.runTransaction((tx)async{
        final latest=await tx.get(ref);final d=latest.data()??<String,dynamic>{};
        final status=(d['status']??'').toString().toLowerCase();
        final isCustomer=d['customerUid']==user.uid;
        final isPartner=d['partnerUid']==user.uid||d['driverUid']==user.uid;
        if(!isCustomer&&!isPartner)throw Exception('You are not part of this ride.');
        if(['cancelled','completed','delivered'].contains(status))return;
        tx.update(ref,{'status':'cancelled','cancelledBy':isCustomer?'customer':'partner','cancellationReason':reason,'cancelledAt':FieldValue.serverTimestamp(),'updatedAt':FieldValue.serverTimestamp()});
      });
      if(mounted){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Ride cancelled.')));Navigator.pop(context);}
    }catch(e){
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Could not cancel ride: '+e.toString().replaceFirst('Exception: ',''))));
    }
  }

  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:Text(widget.title),backgroundColor:const Color(0xFFF8F6F0),foregroundColor:Colors.black,elevation:0),
    backgroundColor:const Color(0xFFF8F6F0),
    body:StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(
      stream:FirebaseFirestore.instance.collection(widget.collection).doc(widget.docId).snapshots(),
      builder:(context,snapshot){
        if(snapshot.hasError)return Center(child:Text('Tracking unavailable: ${snapshot.error}'));
        if(!snapshot.hasData)return const Center(child:CircularProgressIndicator());
        final d=snapshot.data!.data()??<String,dynamic>{};
        final customer=_point(d,'customer');
        LatLng? partner;
        if(widget.mode=='order')partner=_point(d,'carrier');
        else if(widget.mode=='vehicle')partner=_point(d,'owner');
        else partner=_point(d,'partner')??_point(d,'driver');
        final pickup=_point(d,'pickup');
        final destination=_point(d,'destination');
        final points=<LatLng>[if(customer!=null)customer,if(partner!=null)partner,if(pickup!=null)pickup,if(destination!=null)destination];
        final currentUser=FirebaseAuth.instance.currentUser;
        final isCustomer=currentUser!=null&&d['customerUid']==currentUser.uid;
        final routeTarget=(widget.mode=='order'||widget.mode=='ride') ? (destination??pickup) : destination;
        if(partner!=null&&routeTarget!=null&&(!_routeLoading&&(_routePoints.isEmpty||_lastRouteUpdate==null||DateTime.now().difference(_lastRouteUpdate!)>const Duration(seconds:20))))_loadOSRMRoute(partner,routeTarget);
        if(partner!=null&&isCustomer){final base=customer??pickup;if(base!=null)_liveDistanceMeters=Geolocator.distanceBetween(base.latitude,base.longitude,partner.latitude,partner.longitude);}
        if(points.isEmpty)return const Center(child:Padding(padding:EdgeInsets.all(24),child:Text('Waiting for live location. Keep location enabled during the active trip.',textAlign:TextAlign.center)));
        final activeLabel=widget.mode=='order'?'Live delivery tracking':widget.mode=='vehicle'?'Live vehicle tracking':'Live ride tracking';
          final callPhone=(isCustomer?(d['partnerPhone']??d['driverPhone']??d['carrierPhone']??''):(d['customerPhone']??'')).toString();
        return Stack(children:[
          FlutterMap(
            mapController:_mapController,
            options:MapOptions(
              initialCenter:partner??pickup??customer??points.first,
              initialZoom:15,
              onMapReady:(){_mapReady=true;_fitCamera(points);},
            ),
            children:[
              TileLayer(
                urlTemplate:'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                maxZoom:19,
                userAgentPackageName:'com.allways.app',
              ),
              if(_routePoints.isNotEmpty)PolylineLayer(
                polylines:[Polyline(points:_routePoints,color:const Color(0xFF673AB7),strokeWidth:5)],
              ),
              MarkerLayer(markers:_markers(customer:customer,partner:partner,pickup:pickup,destination:destination)),
            ],
          ),
          Positioned(top:12,left:12,right:12,child:SafeArea(bottom:false,child:Card(
            margin:EdgeInsets.zero,
            color:const Color(0xFFFDECEF),
            child:Padding(
              padding:const EdgeInsets.symmetric(horizontal:14,vertical:10),
              child:Row(children:[
                Container(width:10,height:10,decoration:const BoxDecoration(color:Colors.green,shape:BoxShape.circle)),const SizedBox(width:9),
                Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Text(activeLabel,style:const TextStyle(fontWeight:FontWeight.w900)),
                  Text(partner==null?'Waiting for partner location':(_liveDistanceMeters==null?'Partner location is updating live':(_liveDistanceMeters!<1000?_liveDistanceMeters!.round().toString()+' m away':(_liveDistanceMeters!/1000).toStringAsFixed(1)+' km away')),style:const TextStyle(color:Colors.grey,fontSize:12)),
                ])),
                if(callPhone.isNotEmpty)IconButton(onPressed:()=>_call(context,callPhone),icon:const Icon(Icons.call),tooltip:'Call'),
                const Icon(Icons.gps_fixed,size:20),
              ]),
            ),
          ))),
          Positioned(left:12,right:12,bottom:18,child:SafeArea(top:false,child:Card(
            margin:EdgeInsets.zero,
            color:const Color(0xFFFDECEF),
            child:Padding(
              padding:const EdgeInsets.symmetric(horizontal:14,vertical:10),
              child:Row(children:[
                const Icon(Icons.two_wheeler,size:24),const SizedBox(width:8),
                Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  Text(widget.mode=='ride'?'Green pickup • Red destination • Purple moving bike':'Blue customer • Purple moving partner',style:const TextStyle(fontSize:13)),
                  if(_routeDistanceMeters!=null)Text((_routeDistanceMeters!<1000?_routeDistanceMeters!.round().toString()+' m':(_routeDistanceMeters!/1000).toStringAsFixed(1)+' km')+' route • ETA '+((_routeDurationSeconds??0)/60).ceil().toString()+' min',style:const TextStyle(fontSize:12,color:Colors.grey)),
                ])),
                if(widget.allowCancel)TextButton(onPressed:_cancelActiveTrip,child:const Text('Cancel',style:TextStyle(color:Color(0xFF8E5A73)))),
              ]),
            ),
          ))),
        ]);
      },
    ),
  );
}
class Product {
  final String id,name,category,icon,description,brand;
  final num price,stock;
  const Product({required this.id,required this.name,required this.category,required this.icon,required this.description,required this.brand,required this.price,required this.stock});
  factory Product.fromJson(Map<String,dynamic> j){
    num n(dynamic x)=>x is num?x:num.tryParse(x?.toString()??'')??0;
    return Product(id:(j['id']??j['ID']??'').toString(),name:(j['name']??j['title']??j['Product Name']??j['productName']??'Item').toString(),category:(j['category']??j['Category']??j['cat']??'Other').toString().trim(),icon:(j['icon']??j['emoji']??j['Emoji']??'🛍️').toString(),description:(j['description']??j['Description']??'').toString(),brand:(j['brand']??j['Brand']??'').toString(),price:n(j['price']??j['Price']),stock:n(j['stock']??j['Stock']));
  }
}
class CartItem { final Product product; int qty; CartItem(this.product,this.qty); }

class Shell extends StatefulWidget { const Shell({super.key}); State<Shell> createState()=>_ShellState(); }
class _ShellState extends State<Shell> {
  int tab=0; List<Product> products=[]; bool loading=true; String? error; Timer? timer;
  final Map<String,CartItem> cart={}; List<Map<String,dynamic>> addresses=[]; User? user; final Set<String> wishlistIds={};
  StreamSubscription<User?>? auth; StreamSubscription<RemoteMessage>? messages;
  String? updateVersion;
  String? updateUrl;
  String? updateNotes;

  @override void initState(){
    super.initState(); user=FirebaseAuth.instance.currentUser; loadInventory(); checkForUpdate();
    timer=Timer.periodic(const Duration(seconds:30),(_)=>loadInventory(silent:true));
    auth=FirebaseAuth.instance.authStateChanges().listen((u){
      if (!mounted) return;
      setState(() { user=u; });
      if(u!=null){ setupNotifications(); loadAddresses(); loadWishlist(); }
      else{ addresses=[]; wishlistIds.clear(); }
    });
    FirebaseMessaging.onMessageOpenedApp.listen((m){
      final title=m.notification?.title??m.data['title']??'ALLways';
      final body=m.notification?.body??m.data['body']??'Open ALLways to view this update.';
      saveIncomingNotification(title,body,type:(m.data['type']??'announcement').toString());
    });
    FirebaseMessaging.instance.getInitialMessage().then((m){
      if(m==null)return;
      final title=m.notification?.title??m.data['title']??'ALLways';
      final body=m.notification?.body??m.data['body']??'Open ALLways to view this update.';
      saveIncomingNotification(title,body,type:(m.data['type']??'announcement').toString());
    });
    messages=FirebaseMessaging.onMessage.listen((m)async{final title=m.notification?.title??m.data['title']??'ALLways';final body=m.notification?.body??m.data['body']??m.data['message']??'New update';await saveIncomingNotification(title,body,type:(m.data['type']??'announcement').toString());if(!mounted)return;ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(title+': '+body)));});
    if(user!=null){setupNotifications();loadAddresses();loadWishlist();}
  }
  @override void dispose(){timer?.cancel();auth?.cancel();messages?.cancel();super.dispose();}

  Future<void> setupNotifications() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('notifications_enabled') == false) return;

      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        return;
      }

      try {
        await const MethodChannel('com.allways.app/apk_installer')
            .invokeMethod('createNotificationChannel');
      } catch (_) {}

      final notificationsEnabled = prefs.getBool('notifications_enabled') ?? prefs.getBool('allways_notifications_enabled') ?? true;
      if (!notificationsEnabled) return;
      await FirebaseMessaging.instance.subscribeToTopic('all_users');

      final t = await FirebaseMessaging.instance.getToken();

      Future<void> save(String token) async {
        final p = await SharedPreferences.getInstance();
        final preferenceMap = <String,bool>{
          'orderUpdates': p.getBool('notification_orderUpdates') ?? true,
          'deliveryUpdates': p.getBool('notification_deliveryUpdates') ?? true,
          'travelUpdates': p.getBool('notification_travelUpdates') ?? true,
          'offers': p.getBool('notification_offers') ?? true,
          'announcements': p.getBool('notification_announcements') ?? true,
        };
        await p.setString('allways_fcm_token', token);
        if (user != null) {
          try {
            final enabled = p.getBool('notifications_enabled') ?? true;
            final tokenRef = FirebaseFirestore.instance
                .collection('fcmTokens')
                .doc(user!.uid)
                .collection('tokens')
                .doc(token);
            await tokenRef.set({
              'uid': user!.uid,
              'email': user!.email ?? '',
              'token': token,
              'notificationsEnabled': enabled,
              'notificationPreferences': preferenceMap,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
            await FirebaseFirestore.instance
                .collection('fcmTokens')
                .doc(user!.uid)
                .set({
              'uid': user!.uid,
              'email': user!.email ?? '',
              'token': token,
              'notificationsEnabled': enabled,
              'notificationPreferences': preferenceMap,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          } catch (_) {}
        }
      }

      if (t != null && t.isNotEmpty) await save(t);

      FirebaseMessaging.instance.onTokenRefresh.listen((t) async {
        if (t.isNotEmpty) await save(t);
      });
    } catch (_) {}
  }

  Future<void> saveIncomingNotification(String title,String body,{String type='announcement'}) async {
    try{
      final prefs=await SharedPreferences.getInstance();
      final enabled=prefs.getBool('notifications_enabled')??prefs.getBool('allways_notifications_enabled')??true;
      if(!enabled)return;
      final key=type.contains('delivery')?'deliveryUpdates':type.contains('order')?'orderUpdates':(type.contains('ride')||type.contains('vehicle')||type.contains('travel'))?'travelUpdates':type.contains('offer')?'offers':'announcements';
      if(prefs.getBool('notification_'+key)==false)return;
      final raw=prefs.getStringList('allways_notifications')??<String>[];
      raw.insert(0,jsonEncode({'title':title,'body':body,'type':type,'timestamp':DateTime.now().millisecondsSinceEpoch,'read':false}));
      unreadNotificationNotifier.value = true;
      if(raw.length>50)raw.removeRange(50,raw.length);
      await prefs.setStringList('allways_notifications',raw);
    }catch(_){}
  }

  Future<void> setNotificationsEnabled(bool enabled) async {
    final prefs=await SharedPreferences.getInstance();
    if(enabled){
      final settings=await FirebaseMessaging.instance.requestPermission(alert:true,badge:true,sound:true,provisional:false);
      if(settings.authorizationStatus==AuthorizationStatus.denied){await prefs.setBool('allways_notifications_enabled',false);await prefs.setBool('notifications_enabled',false);return;}
      await FirebaseMessaging.instance.subscribeToTopic('all_users');
      await prefs.setBool('allways_notifications_enabled',true);
      await prefs.setBool('notifications_enabled',true);
      await setupNotifications();
    }else{
      await FirebaseMessaging.instance.unsubscribeFromTopic('all_users');
      await prefs.setBool('allways_notifications_enabled',false);
      await prefs.setBool('notifications_enabled',false);
      if(user!=null){try{
        final token=await FirebaseMessaging.instance.getToken();
        await FirebaseFirestore.instance.collection('fcmTokens').doc(user!.uid).set({'uid':user!.uid,'notificationsEnabled':false,'updatedAt':FieldValue.serverTimestamp()},SetOptions(merge:true));
        if(token!=null&&token.isNotEmpty){
          await FirebaseFirestore.instance.collection('fcmTokens').doc(user!.uid).collection('tokens').doc(token).set({'uid':user!.uid,'token':token,'notificationsEnabled':false,'updatedAt':FieldValue.serverTimestamp()},SetOptions(merge:true));
        }
      }catch(_){}}
    }
  }

  Future<void> checkForUpdate() async {
    try {
      final r=await http.get(Uri.parse(updateManifestUrl)).timeout(const Duration(seconds:8));
      if(r.statusCode!=200)return;
      final data=jsonDecode(r.body);
      if(data is! Map)return;
      final remote=(data['version']??'').toString();
      final url=(data['apkUrl']??'').toString();
      if(remote.isEmpty||url.isEmpty)return;
      final info=await PackageInfo.fromPlatform();
      if(_versionGreater(remote,info.version)){
        if(!mounted)return;
        setState((){updateVersion=remote;updateUrl=url;updateNotes=(data['notes']??'').toString();});
      }
    }catch(_){}
  }

  bool _versionGreater(String remote,String local){
    List<int> p(String v)=>v.split('.').map((x)=>int.tryParse(x.replaceAll(RegExp(r'[^0-9]'),''))??0).toList();
    final a=p(remote),b=p(local);
    for(var i=0;i<3;i++){final x=i<a.length?a[i]:0,y=i<b.length?b[i]:0;if(x!=y)return x>y;}
    return false;
  }

  Future<void> openUpdate() async {
    final u=updateUrl;
    if(u==null||u.isEmpty)return;
    final messenger=ScaffoldMessenger.of(context);
    final controller=ValueNotifier<double>(0);
    try {
      showDialog(context:context,barrierDismissible:false,builder:(_)=>AlertDialog(
        title:const Text('Updating ALLways'),
        content:ValueListenableBuilder<double>(valueListenable:controller,builder:(_,p,__)=>Column(
          mainAxisSize:MainAxisSize.min,
          children:[LinearProgressIndicator(value:p>0?p:null),const SizedBox(height:12),
            Text(p>0?'Downloading '+(p*100).toStringAsFixed(0)+'%':'Starting download…')]
        )),
      ));
      final file=File(Directory.systemTemp.path+'/allways_update_'+DateTime.now().millisecondsSinceEpoch.toString()+'.apk');
      final downloadUrl=u+(u.contains('?')?'&':'?')+'cacheBust='+DateTime.now().millisecondsSinceEpoch.toString();
      await Dio().download(downloadUrl,file.path,deleteOnError:true,onReceiveProgress:(received,total){if(total>0)controller.value=received/total;});
      if(mounted)Navigator.of(context).pop();
      final result=await const MethodChannel('com.allways.app/apk_installer').invokeMethod<String>('installApk',{'path':file.path});
      if(result=='permission_required'){
        try{
          await const MethodChannel('com.allways.app/apk_installer').invokeMethod('openInstallSettings');
        }catch(_){}
        messenger.showSnackBar(const SnackBar(content:Text('Please allow ALLways to install updates, then tap Update again.')));
      }
      else if(result!='started')messenger.showSnackBar(SnackBar(content:Text('Could not start installation: '+(result??'unknown error'))));
    }catch(e){
      if(mounted&&Navigator.of(context).canPop())Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content:Text('Update failed: '+e.toString())));
    }finally{controller.dispose();}
  }
  Future<List<Product>> _loadInventoryFallback() async {
    try {
      final productSnap = await FirebaseFirestore.instance.collection('products').limit(1000).get();
      if (productSnap.docs.isNotEmpty) {
        return productSnap.docs.map((d) {
          final data = Map<String, dynamic>.from(d.data());
          data['id'] = (data['id'] ?? d.id).toString();
          return Product.fromJson(data);
        }).toList();
      }
    } catch (_) {}

    try {
      final inventorySnap = await FirebaseFirestore.instance.collection('inventory').limit(1000).get();
      if (inventorySnap.docs.isNotEmpty) {
        return inventorySnap.docs.map((d) {
          final data = Map<String, dynamic>.from(d.data());
          data['id'] = (data['id'] ?? d.id).toString();
          return Product.fromJson(data);
        }).toList();
      }
    } catch (_) {}

    return <Product>[];
  }

  Future<void> loadInventory({bool silent=false}) async {
    if(!silent&&mounted)setState(()=>loading=true);
    Object? firestoreError;
    try{
      // Firestore is the authoritative customer catalog. The Admin app syncs
      // Google Sheets into products/{id} and inventory/{id}.
      final snap=await FirebaseFirestore.instance.collection('products').limit(1000).get();
      if(snap.docs.isNotEmpty){
        final list=snap.docs.map((d){
          final data=Map<String,dynamic>.from(d.data());
          data['id']=(data['id']??d.id).toString();
          if(data['icon']==null&&data['emoji']!=null)data['icon']=data['emoji'];
          if(data['available']==false)data['stock']=0;
          return Product.fromJson(data);
        }).where((p)=>p.id.isNotEmpty&&p.name.isNotEmpty).toList();
        if(list.isNotEmpty){
          if(mounted)setState((){products=list;loading=false;error=null;});
          return;
        }
      }
    }catch(e){
      firestoreError=e;
    }

    // Try the legacy inventory collection before going to the external
    // catalog endpoint. Older Admin syncs may have inventory documents even
    // when products/{id} is empty.
    try{
      final inventorySnap=await FirebaseFirestore.instance.collection('inventory').limit(1000).get();
      if(inventorySnap.docs.isNotEmpty){
        final list=inventorySnap.docs.map((d){
          final data=Map<String,dynamic>.from(d.data());
          data['id']=(data['id']??d.id).toString();
          if(data['icon']==null&&data['emoji']!=null)data['icon']=data['emoji'];
          if(data['available']==false)data['stock']=0;
          return Product.fromJson(data);
        }).where((p)=>p.id.isNotEmpty&&p.name.isNotEmpty).toList();
        if(list.isNotEmpty){
          if(mounted)setState((){products=list;loading=false;error=null;});
          return;
        }
      }
    }catch(e){
      firestoreError=firestoreError??e;
    }

    // If Firestore has not been synced yet, use the configured Google Apps
    // Script catalog endpoint. Admin stores the active deployment URL in
    // settings/catalogSync so a redeployment does not require a new APK.
    var catalogEndpoint=inventoryEndpoint;
    try{
      final settings=await FirebaseFirestore.instance.collection('settings').doc('catalogSync').get();
      final configured=(settings.data()?['endpoint']??'').toString().trim();
      if(configured.isNotEmpty) catalogEndpoint=configured;
    }catch(_){}

    try{
      // Google Apps Script may respond through a redirect. Dio is already
      // used by ALLways and gives us explicit redirect handling plus a clearer
      // network error than the basic http client.
      final response=await Dio(
        BaseOptions(
          followRedirects:true,
          maxRedirects:8,
          connectTimeout:const Duration(seconds:12),
          receiveTimeout:const Duration(seconds:25),
          headers:const {
            'Accept':'application/json',
            'Cache-Control':'no-cache',
          },
          validateStatus:(status)=>status!=null&&status>=200&&status<400,
        ),
      ).get(
        catalogEndpoint+'?_='+DateTime.now().millisecondsSinceEpoch.toString(),
        options:Options(responseType:ResponseType.plain),
      );
      final status=response.statusCode??0;
      if(status==404)throw Exception('Google Apps Script /exec URL is not active (HTTP 404). Update the endpoint in Admin → Catalog Sync after redeploying the Apps Script.');
      if(status<200||status>=300)throw Exception('Inventory server error: HTTP '+status.toString());
      final body=response.data?.toString()??'';
      if(body.trim().isEmpty)throw Exception('Inventory server returned an empty response');
      dynamic decoded=jsonDecode(body.trim().replaceFirst('﻿',''));
      if(decoded is String)decoded=jsonDecode(decoded);
      final raw=decoded is Map ? (decoded['products']??decoded['data']??decoded['items']??decoded) : decoded;
      if(raw is! List)throw Exception('Invalid inventory response');
      final list=raw.whereType<Map>().map((x){
        final data=Map<String,dynamic>.from(x);
        if(data['icon']==null&&data['Emoji']!=null)data['icon']=data['Emoji'];
        if(data['emoji']!=null&&data['icon']==null)data['icon']=data['emoji'];
        return Product.fromJson(data);
      }).where((p)=>p.id.isNotEmpty&&p.name.isNotEmpty).toList();
      if(list.isEmpty)throw Exception('Inventory response contained no products');
      if(mounted)setState((){products=list;loading=false;error=null;});
      return;
    }catch(e){
      final fallbackError=e;
      if(mounted&&!silent){
        setState((){
          loading=false;
          error='Inventory unavailable. Firestore: '+(firestoreError?.toString()??'not synced')+' | Catalog: '+fallbackError.toString();
        });
      }
    }
  }
  int get count=>cart.values.fold(0,(s,x)=>s+x.qty);
  num get total=>cart.values.fold(0,(s,x)=>s+x.product.price*x.qty);

  void add(Product p){
    if(user==null){login();return;} if(p.stock<=0)return;
    final q=cart[p.id]?.qty??0;
    if(q>=p.stock){msg('Only '+p.stock.toString()+' available.');return;}
    setState(()=>cart[p.id]=CartItem(p,q+1));msg(p.name+' added to cart');
  }
  void qty(String id,int d){
    final item=cart[id];
    if(item==null)return;
    final current=item.qty;
    final next=current+d;
    if(d<0){
      if(current>1){
        setState(()=>item.qty=current-1);
      }else{
        setState(()=>cart.remove(id));
      }
      return;
    }
    if(d>0){
      if(next<=item.product.stock){
        setState(()=>item.qty=next);
      }else{
        msg('Only '+item.product.stock.toString()+' available.');
      }
    }
  }
  void msg(String s){if(!mounted)return;ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));}
  void login(){Navigator.push(context,MaterialPageRoute(builder:(_)=>const AuthScreen()));}

  Future<void> loadWishlist() async {
    if(user==null)return;
    try{
      final snap=await FirebaseFirestore.instance.collection('customers').doc(user!.uid).collection('wishlist').get();
      wishlistIds..clear()..addAll(snap.docs.map((d)=>d.id));
      if(mounted)setState((){});
    }catch(_){}
  }

  Future<void> toggleWishlist(Product p) async {
    if(user==null){login();return;}
    final ref=FirebaseFirestore.instance.collection('customers').doc(user!.uid).collection('wishlist').doc(p.id);
    final adding=!wishlistIds.contains(p.id);
    setState((){if(adding)wishlistIds.add(p.id);else wishlistIds.remove(p.id);});
    try{
      if(adding){
        await ref.set({'id':p.id,'name':p.name,'category':p.category,'icon':p.icon,'description':p.description,'brand':p.brand,'price':p.price,'stock':p.stock,'addedAt':FieldValue.serverTimestamp()});
        msg('Added to wishlist');
      }else{
        await ref.delete();
        msg('Removed from wishlist');
      }
    }catch(_){
      setState((){if(adding)wishlistIds.remove(p.id);else wishlistIds.add(p.id);});
      msg('Could not update wishlist. Please try again.');
    }
  }

  Future<void> cancelOrder(String payload) async {
    if(user==null)return;
    final parts=payload.split('||');final orderId=parts.first;final reason=parts.length>1&&parts[1].trim().isNotEmpty?parts.sublist(1).join('||').trim():'Customer requested cancellation';
    try{
      final snap=await FirebaseFirestore.instance.collection('orders').doc(orderId).get();
      if(!snap.exists){msg('Order not found.');return;}
      final o=snap.data()??{};if(o['customerId']!=user!.uid){msg('You cannot cancel this order.');return;}
      final status=(o['status']??'').toString();if(status!='New Order'&&status!='Confirmed'){msg('This order can no longer be cancelled.');return;}
      await FirebaseFirestore.instance.collection('orders').doc(orderId).update({'status':'Cancelled','statusNote':'Cancelled by customer','cancellationReason':reason,'updatedAt':DateTime.now().millisecondsSinceEpoch});
      msg('Order #'+orderId+' cancelled.');
    }catch(e){msg('Could not cancel the order. Please try again.');}
  }

  Future<void> loadAddresses() async {
    if(user==null)return;
    try{
      final s=await FirebaseFirestore.instance.collection('customers').doc(user!.uid).collection('addresses').orderBy('createdAt',descending:true).get();
      addresses=s.docs.map((d)=>{'id':d.id,...d.data()}).toList();
      if(mounted)setState((){});
    }catch(_){addresses=[];}
  }
  Future<void> saveAddress(String n,String ph,String a,{double? latitude,double? longitude}) async {
    if(user==null)return;
    try{
      await FirebaseFirestore.instance.collection('customers').doc(user!.uid).collection('addresses').add({'name':n,'phone':ph,'address':a,'latitude':latitude,'longitude':longitude,'isCurrent':true,'createdAt':FieldValue.serverTimestamp()});
      await loadAddresses();
    }catch(_){}
  }
  Future<void> deleteAddress(String id) async {
    if(user==null)return;
    try{await FirebaseFirestore.instance.collection('customers').doc(user!.uid).collection('addresses').doc(id).delete();await loadAddresses();}catch(_){}
  }

  Future<void> placeOrder(String name,String phone,String address,String note,double? latitude,double? longitude,String deliveryType,DateTime? scheduledFor) async {
    if(user==null){login();return;} if(cart.isEmpty)return;
    await setupNotifications();
    final ph=phone.replaceAll(RegExp(r'\D'),'');
    if(name.trim().isEmpty||!RegExp(r'^\d{10}$').hasMatch(ph)||address.trim().isEmpty){msg('Enter name, valid 10-digit phone and address.');return;}

    final settings=await loadDeliverySettings();
    final scheduled=(deliveryType=='scheduled');
    if(!deliveryBool(settings,'deliveryEnabled',true)){msg('ALLways delivery is temporarily unavailable.');return;}
    if(scheduled && !deliveryBool(settings,'scheduledEnabled',true)){msg('Scheduled delivery is currently unavailable.');return;}
    if(!scheduled && !deliveryBool(settings,'instantEnabled',true)){msg('Instant delivery is currently unavailable.');return;}
    if(scheduled && DateTime.now().isAfter(scheduledCutoffNow(settings))){
      msg('Scheduled orders are closed for today. You can still place an instant order.');
      return;
    }
    if(scheduled && scheduledFor!=null && scheduledFor.isBefore(DateTime.now().add(const Duration(minutes:30)))){
      msg('Choose a scheduled time at least 30 minutes from now.');return;
    }
    if(scheduled && scheduledFor==null){msg('Please choose a scheduled delivery time.');return;}

    for(final x in cart.values){
      final p=products.where((z)=>z.id==x.product.id).firstOrNull;
      if(p==null||p.stock<x.qty){msg(x.product.name+' is no longer available.');await loadInventory();return;}
    }

    final sub=total;
    final threshold=deliveryNum(settings,'freeScheduledThreshold',499).toDouble();
    final centerLat=deliveryNum(settings,'pilotCenterLat',0).toDouble();
    final centerLng=deliveryNum(settings,'pilotCenterLng',0).toDouble();
    final radius=deliveryNum(settings,'pilotRadiusKm',4).toDouble();
    double distanceKm=0;
    if(centerLat!=0&&centerLng!=0&&latitude!=null&&longitude!=null){
      distanceKm=Geolocator.distanceBetween(latitude,longitude,centerLat,centerLng)/1000;
      if(radius>0&&distanceKm>radius){
        msg('This address is outside the current ALLways delivery area.');return;
      }
    }else if(centerLat!=0&&centerLng!=0){
      msg('Use current location so ALLways can calculate the delivery distance.');return;
    }else{
      msg('Delivery area is not configured yet. Please contact ALLways operations.');return;
    }

    final km=chargeableKm(distanceKm);
    final scheduledFree=scheduled && sub>=threshold;
    final delivery=scheduled
        ? (scheduledFree ? 0 : km*deliveryNum(settings,'scheduledPerKm',11))
        : deliveryNum(settings,'instantBaseFee',35)+km*deliveryNum(settings,'instantPerKm',11);
    final grand=sub+delivery;
    final id='AW'+DateTime.now().millisecondsSinceEpoch.toString().substring(4);

    final order={
      'id':id,'customerId':user!.uid,'customerUid':user!.uid,'email':user!.email??'',
      'name':name.trim(),'phone':ph,'address':address.trim(),'note':note.trim(),
      'customerLatitude':latitude,'customerLongitude':longitude,
      'locationSource':latitude!=null&&longitude!=null?'gps':'address',
      'items':cart.values.map((x)=>{'id':x.product.id,'name':x.product.name,'qty':x.qty,'price':x.product.price}).toList(),
      'subtotal':sub,'delivery':delivery,'deliveryFee':delivery,'total':grand,
      'deliveryType':scheduled?'scheduled':'instant',
      'scheduledFor':scheduledFor?.millisecondsSinceEpoch,
      'deliveryDistanceKm':distanceKm,
      'deliveryChargeableKm':km,
      'freeScheduledDelivery':scheduledFree,
      'freeScheduledThreshold':threshold,
      'deliveryPricingRule':scheduled
          ? (scheduledFree?'scheduled_free_over_threshold':'scheduled_per_km')
          : 'instant_base_plus_per_km',
      'deliveryZoneId':'pilot_zone','deliveryZoneName':'ALLways Pilot Zone',
      'paymentMethod':'COD','status':'New Order','estimatedDelivery':'','eta':'',
      'carrierUid':null,'deliveryPartnerUid':null,'carrierAccepted':false,
      'statusNote':'Order received','customerMessage':'Order received','cancellationReason':'','rating':null,
      'fcmToken':(await SharedPreferences.getInstance()).getString('allways_fcm_token')??'',
      'customer_fcm_token':(await SharedPreferences.getInstance()).getString('allways_fcm_token')??'',
      'createdAt':DateTime.now().millisecondsSinceEpoch,'updatedAt':DateTime.now().millisecondsSinceEpoch,
      'time':DateTime.now().toLocal().toString(),
    };
    try{
      await FirebaseFirestore.instance.collection('orders').doc(id).set(order);
      await saveAddress(name.trim(),ph,address.trim(),latitude:latitude,longitude:longitude);
      setState(()=>cart.clear());
      if(mounted){
        Navigator.of(context).pop();
        setState(()=>tab=0);
        await _showOrderSuccess(id);
      }
    }catch(e){msg('Order could not be saved. Please try again.');}
  }

  Future<void> _enableOrderNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('allways_notifications_enabled', true);
    await prefs.setBool('notifications_enabled', true);
    await prefs.setBool('notification_orderUpdates', true);
    await setupNotifications();
  }

  Future<void> _showOrderSuccess(String orderId) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Dialog.fullscreen(
        child: _OrderSuccessScreen(
          orderId: orderId,
          onContinueShopping: () => Navigator.of(dialogContext).pop(),
          onTrackOrder: () {
            Navigator.of(dialogContext).pop();
            Navigator.of(context).pushNamed('/order-details', arguments: {'orderId': orderId});
          },
          onEnableNotifications: () async {
            await _enableOrderNotifications();
            if (dialogContext.mounted) Navigator.of(dialogContext).pop();
          },
        ),
      ),
    );
  }

  Future<void> reorderItems(List<Map<String, dynamic>> rawItems) async {
    if (user == null) { login(); return; }
    if (products.isEmpty) await loadInventory();
    int added=0, skipped=0;
    for(final raw in rawItems){
      final id=(raw['id']??'').toString();
      Product? product;
      for(final p in products){if(p.id==id){product=p;break;}}
      if(product==null||product.stock<=0){skipped++;continue;}
      final requested=raw['qty'] is num ? (raw['qty'] as num).toInt() : int.tryParse((raw['qty']??1).toString())??1;
      final wanted=requested<1?1:requested;
      final existing=cart[product.id]?.qty??0;
      final available=product.stock.toInt();
      final next=(existing+wanted)>available?available:(existing+wanted);
      if(next<=existing){skipped++;continue;}
      cart[product.id]=CartItem(product,next);added++;
    }
    if(mounted)setState((){});
    if(added==0){msg('None of the delivered items are currently available.');return;}
    msg(skipped>0?'$added item(s) added. $skipped unavailable item(s) were skipped.':'Your delivered items were added to the cart.');
    if(!mounted)return;
    await Navigator.push(context,MaterialPageRoute(builder:(_)=>CartScreen(cart:cart,addresses:addresses,onQty:qty,onPlace:placeOrder)));
    if(mounted)setState((){});
  }

  Widget build(BuildContext c){
    final pages=[
      ShopPage(products:products,loading:loading,error:error,onRefresh:loadInventory,onAdd:add,cart:cart,onQty:qty,user:user,wishlistIds:wishlistIds,onWishlist:toggleWishlist,onOpenCart:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>CartScreen(cart:cart,addresses:addresses,onQty:qty,onPlace:placeOrder))),addresses:addresses),
      const TravelPage(),
      ProfilePage(user:user,addresses:addresses,onLogin:login,onReload:loadAddresses,onDelete:deleteAddress,onCancel:cancelOrder,onReorder:reorderItems,onAdd:add),
    ];
    return ValueListenableBuilder<String>(valueListenable:languageNotifier,builder:(context,lang,_)=>Scaffold(
      body:SafeArea(child:Column(children:[
        if(updateVersion!=null)
          MaterialBanner(
            content:Text('New ALLways update '+updateVersion!+(updateNotes!.isEmpty?'':' — '+updateNotes!)),
            leading:const Icon(Icons.system_update),
            actions:[TextButton(onPressed:openUpdate,child:const Text('UPDATE NOW'))],
          ),
        Expanded(child:pages[tab]),
      ])),
      bottomNavigationBar:AllwaysBottomNav(
        selectedIndex:tab,
        onSelected:(i)=>setState(()=>tab=i),
        items:[
          (icon:Icons.shopping_bag_outlined,activeIcon:Icons.shopping_bag,label:tr('Shop')),
          (icon:Icons.directions_car_outlined,activeIcon:Icons.directions_car,label:tr('Travel')),
          (icon:Icons.person_outline,activeIcon:Icons.person,label:tr('Profile')),
        ],
      ),
      floatingActionButton:count==0?null:FloatingActionButton.extended(
        onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>CartScreen(cart:cart,addresses:addresses,onQty:qty,onPlace:placeOrder))),
        icon:const Icon(Icons.shopping_cart),label:Text(count.toString()+' • ₹'+total.toStringAsFixed(0))),
    ));
  }
}

class ShopPage extends StatefulWidget{
  final List<Product> products;
  final bool loading;
  final String? error;
  final Future<void> Function({bool silent}) onRefresh;
  final void Function(Product) onAdd;
  final Map<String,CartItem> cart;
  final void Function(String,int) onQty;
  final User? user;
  final Set<String> wishlistIds;
  final Future<void> Function(Product) onWishlist;
  final VoidCallback onOpenCart;
  final List<Map<String,dynamic>> addresses;
  const ShopPage({super.key,required this.products,required this.loading,required this.error,required this.onRefresh,required this.onAdd,required this.cart,required this.onQty,required this.user,required this.wishlistIds,required this.onWishlist,required this.onOpenCart,required this.addresses});
  @override State<ShopPage> createState()=>_ShopPageState();
}

class _ShopPageState extends State<ShopPage>{
  final searchController=TextEditingController();
  final stt.SpeechToText speech=stt.SpeechToText();
  String search='',location='Select delivery location';
  bool locating=false,listening=false;
  Timer? bannerTimer;
  int bannerIndex=0;
  static const green=AllwaysColors.primary;
  static const preferred=['Popular Near You','Daily Needs','Fresh Fruits & Vegetables','Dairy','Grocery','Bakery','Snacks','Beverages','Breakfast Essentials','Rice & Grains','Atta & Flour','Pulses & Dal','Cooking Oil','Spices & Masala','Salt & Sugar','Dry Fruits & Nuts','Tea & Coffee','Biscuits & Cookies','Chocolates & Sweets','Instant Food','Noodles & Pasta','Sauces & Spreads','Pickles & Chutneys','Canned & Packaged Food','Frozen Food','Ice Cream','Meat & Seafood','Eggs','Personal Care','Bath & Body','Hair Care','Oral Care','Skin Care','Baby Care','Health & Wellness','Home Care','Cleaning Essentials','Laundry Care','Dishwashing','Kitchen Essentials','Paper & Tissue','Pet Care','Stationery','Electronics','Mobile Accessories','Household Essentials','Pooja Essentials','Organic & Natural','Local Specials','Seasonal Products'];
  static const icons={'All':'▦','Dairy':'🥛','Grocery':'🛒','Fruits & Vegetables':'🥬','Bakery':'🥖','Snacks':'🍟','Beverages':'🥤','Breakfast Essentials':'🍳','Rice & Grains':'🍚','Atta & Flour':'🌾','Pulses & Dal':'🫘','Cooking Oil':'🫗','Spices & Masala':'🌶️','Salt & Sugar':'🧂','Dry Fruits & Nuts':'🥜','Tea & Coffee':'☕','Biscuits & Cookies':'🍪','Chocolates & Sweets':'🍫','Instant Food':'🍜','Noodles & Pasta':'🍝','Sauces & Spreads':'🥫','Pickles & Chutneys':'🫙','Canned & Packaged Food':'📦','Frozen Food':'🧊','Ice Cream':'🍦','Meat & Seafood':'🥩','Eggs':'🥚','Personal Care':'🧴','Bath & Body':'🛁','Hair Care':'💇','Oral Care':'🪥','Skin Care':'🧖','Baby Care':'🍼','Health & Wellness':'💊','Home Care':'🏠','Cleaning Essentials':'🧹','Laundry Care':'🧺','Dishwashing':'🧽','Kitchen Essentials':'🍳','Paper & Tissue':'🧻','Pet Care':'🐾','Stationery':'📚','Electronics':'🔌','Mobile Accessories':'📱','Household Essentials':'🧰','Pooja Essentials':'🪔','Organic & Natural':'🌿','Local Specials':'⭐','Seasonal Products':'🎉'};

  @override void initState(){super.initState();syncLocation();bannerTimer=Timer.periodic(const Duration(seconds:4),(_){if(mounted)setState(()=>bannerIndex++);});}
  @override void dispose(){bannerTimer?.cancel();searchController.dispose();speech.stop();super.dispose();}
  @override void didUpdateWidget(covariant ShopPage old){super.didUpdateWidget(old);if(widget.addresses!=old.addresses)syncLocation();}
  void syncLocation(){if(widget.addresses.isNotEmpty){final x=widget.addresses.firstWhere((x)=>x['isCurrent']==true,orElse:()=>widget.addresses.first);final v=(x['address']??'').toString().trim();if(v.isNotEmpty)location=v;}}
  Future<void> voice()async{try{final ok=await speech.initialize(onStatus:(s){if(mounted&&s!='listening')setState(()=>listening=false);},onError:(_){if(mounted)setState(()=>listening=false);});if(!ok)return;setState(()=>listening=true);await speech.listen(onResult:(r){if(!mounted)return;searchController.text=r.recognizedWords;searchController.selection=TextSelection.fromPosition(TextPosition(offset:searchController.text.length));setState(()=>search=searchController.text);},listenOptions:stt.SpeechListenOptions(partialResults:true));}catch(_){if(mounted)setState(()=>listening=false);}}
  Future<void> changeLocation()async{if(widget.user==null){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Sign in to select your delivery location.')));return;}await showModalBottomSheet(context:context,showDragHandle:true,builder:(sheet)=>SafeArea(child:ListView(children:[const ListTile(title:Text('Choose delivery location',style:TextStyle(fontSize:20,fontWeight:FontWeight.w900))),...widget.addresses.take(8).map((x)=>ListTile(leading:const Icon(Icons.location_on_outlined),title:Text((x['name']??'Saved address').toString()),subtitle:Text((x['address']??'').toString()),onTap:(){final v=(x['address']??'').toString();if(v.isNotEmpty)setState(()=>location=v);Navigator.pop(sheet);})),ListTile(leading:const Icon(Icons.my_location),title:const Text('Use current location'),onTap:()async{Navigator.pop(sheet);await currentLocation();})])));}
  Future<void> currentLocation()async{if(locating)return;setState(()=>locating=true);try{if(!await Geolocator.isLocationServiceEnabled())throw Exception('Turn on GPS first.');var p=await Geolocator.checkPermission();if(p==LocationPermission.denied)p=await Geolocator.requestPermission();if(p==LocationPermission.denied||p==LocationPermission.deniedForever)throw Exception('Location permission was not granted.');final pos=await Geolocator.getCurrentPosition(locationSettings:const LocationSettings(accuracy:LocationAccuracy.high)).timeout(const Duration(seconds:10));var a='Latitude: '+pos.latitude.toString()+', Longitude: '+pos.longitude.toString();try{final m=await placemarkFromCoordinates(pos.latitude,pos.longitude);if(m.isNotEmpty){final x=m.first;final parts=[x.street,x.subLocality,x.locality,x.subAdministrativeArea,x.administrativeArea,x.postalCode].whereType<String>().where((v)=>v.trim().isNotEmpty).map((v)=>v.trim()).toList();if(parts.isNotEmpty)a=parts.toSet().join(', ');}}catch(_){}await FirebaseFirestore.instance.collection('customers').doc(widget.user!.uid).collection('addresses').doc('current_location').set({'name':'Current location','address':a,'latitude':pos.latitude,'longitude':pos.longitude,'isCurrent':true,'createdAt':FieldValue.serverTimestamp()},SetOptions(merge:true));if(mounted)setState(()=>location=a);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString())));}finally{if(mounted)setState(()=>locating=false);}}
  List<String> get cats{final found=<String>{for(final p in widget.products)if(p.category.trim().isNotEmpty)p.category.trim()};final out=<String>[];for(final x in preferred)if(found.contains(x))out.add(x);out.addAll(found.where((x)=>!out.contains(x)).toList()..sort());return ['All',...out];}
  List<Product> byCat(String n)=>n=='All'?List<Product>.from(widget.products):widget.products.where((p)=>p.category.trim().toLowerCase()==n.trim().toLowerCase()).toList();
  void openCat(BuildContext c,String n)=>Navigator.push(c,MaterialPageRoute(builder:(_)=>CategoryProductsPage(category:n,products:byCat(n),onAdd:widget.onAdd,cart:widget.cart,onQty:widget.onQty,wishlistIds:widget.wishlistIds,onWishlist:widget.onWishlist)));
  Widget categoryChip(BuildContext c,String n)=>InkWell(onTap:()=>openCat(c,n),borderRadius:BorderRadius.circular(16),child:SizedBox(width:76,child:Column(children:[Container(height:60,width:60,decoration:BoxDecoration(color:n=='All'?const Color(0xFFE7F7EE):const Color(0xFFF4F4F4),borderRadius:BorderRadius.circular(18)),alignment:Alignment.center,child:Text(icons[n]??'🛍️',style:const TextStyle(fontSize:28))),const SizedBox(height:5),Text(n,maxLines:1,overflow:TextOverflow.ellipsis,textAlign:TextAlign.center,style:const TextStyle(fontSize:10.5,fontWeight:FontWeight.w700))])));
  Widget productCard(BuildContext c,Product p){
    final item=widget.cart[p.id];
    final liked=widget.wishlistIds.contains(p.id);
    return Card(
      elevation:0,
      margin:EdgeInsets.zero,
      shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(14)),
      clipBehavior:Clip.antiAlias,
      child:InkWell(
        onTap:()=>Navigator.push(
          c,
          MaterialPageRoute(
            builder:(_)=>ProductScreen(
              product:p,
              onAdd:()=>widget.onAdd(p),
              liked:liked,
              onWishlist:()=>widget.onWishlist(p),
            ),
          ),
        ),
        child:Padding(
          padding:const EdgeInsets.all(8),
          child:Column(
            crossAxisAlignment:CrossAxisAlignment.start,
            children:[
              Stack(
                children:[
                  Container(
                    height:96,
                    width:double.infinity,
                    alignment:Alignment.center,
                    decoration:BoxDecoration(
                      color:const Color(0xFFF5F5F5),
                      borderRadius:BorderRadius.circular(12),
                    ),
                    child:Text(p.icon,style:const TextStyle(fontSize:42)),
                  ),
                  Positioned(
                    right:-2,
                    top:-2,
                    child:IconButton(
                      visualDensity:VisualDensity.compact,
                      onPressed:()=>widget.onWishlist(p),
                      icon:Icon(liked?Icons.favorite:Icons.favorite_border,color:Colors.red,size:20),
                    ),
                  ),
                ],
              ),
              const SizedBox(height:6),
              Text(p.name,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:12,fontWeight:FontWeight.w800)),
              Text(p.category,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:10,color:Colors.grey)),
              const Spacer(),
              Text('₹'+p.price.toString(),style:const TextStyle(fontSize:13,fontWeight:FontWeight.w900)),
              const SizedBox(height:5),
              if(item==null)
                SizedBox(
                  height:32,
                  width:double.infinity,
                  child:FilledButton(
                    style:FilledButton.styleFrom(backgroundColor:green,foregroundColor:Colors.white,padding:EdgeInsets.zero),
                    onPressed:p.stock>0?()=>widget.onAdd(p):null,
                    child:const Text('ADD',style:TextStyle(fontSize:11,fontWeight:FontWeight.w900)),
                  ),
                )
              else
                Container(
                  height:32,
                  decoration:BoxDecoration(color:const Color(0xFFE7F7EE),borderRadius:BorderRadius.circular(16)),
                  child:Row(
                    children:[
                      Expanded(child:IconButton(visualDensity:VisualDensity.compact,padding:EdgeInsets.zero,onPressed:()=>widget.onQty(p.id,-1),icon:const Icon(Icons.remove,size:16,color:green))),
                      Expanded(child:Center(child:Text(item.qty.toString(),style:const TextStyle(fontWeight:FontWeight.w900)))),
                      Expanded(child:IconButton(visualDensity:VisualDensity.compact,padding:EdgeInsets.zero,onPressed:p.stock>item.qty?()=>widget.onQty(p.id,1):null,icon:const Icon(Icons.add,size:16,color:green))),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
  Widget productSection(BuildContext c,String title,List<Product> items,{bool seeAll=true}){
    if(items.isEmpty)return const SizedBox.shrink();
    final show=items.take(3).toList();
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Row(children:[Expanded(child:Text(title,style:const TextStyle(fontSize:20,fontWeight:FontWeight.w900))),if(seeAll)TextButton(onPressed:()=>openCat(c,title=='Top offers'?'All':title),child:const Text('See all'))]),
      GridView.builder(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),itemCount:show.length,gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:3,crossAxisSpacing:8,mainAxisSpacing:10,childAspectRatio:.60),itemBuilder:(c,i)=>productCard(c,show[i])),
      const SizedBox(height:16),
    ]);
  }

  @override Widget build(BuildContext c){
    final q=search.trim().toLowerCase();
    final searched=q.isEmpty?widget.products:widget.products.where((p)=>(p.name+' '+p.category+' '+p.brand+' '+p.description).toLowerCase().contains(q)).toList();
    final cs=cats;
    final sections=<String>[];
    for(final x in preferred){if(byCat(x).isNotEmpty)sections.add(x);}
    for(final x in cs.skip(1)){if(!sections.contains(x)&&byCat(x).isNotEmpty)sections.add(x);}
    return StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(
      stream:FirebaseFirestore.instance.collection('settings').doc('homepage').snapshots(),
      builder:(context,homeSnap){
        final h=homeSnap.data?.data()??<String,dynamic>{};
        final showCategories=h['showCategories']!=false,showOffers=h['showOffers']!=false,showPopular=h['showPopular']!=false;
        final heroTitle=(h['heroTitle']??'Closer to You, Always').toString();
        final heroSubtitle=(h['heroSubtitle']??'Everything you need, delivered locally.').toString();
        final deliveryText=(h['deliveryText']??'Fast local delivery').toString();
        return RefreshIndicator(
          onRefresh:()=>widget.onRefresh(),
          child:ListView(padding:const EdgeInsets.fromLTRB(12,8,12,110),children:[
            Row(children:[
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                RichText(
                  text:TextSpan(
                    style:const TextStyle(fontSize:30,fontWeight:FontWeight.w900),
                    children:[
                      const TextSpan(text:'ALL',style:TextStyle(color:AllwaysColors.purple)),
                      TextSpan(text:'ways',style:TextStyle(color:Theme.of(c).colorScheme.onSurface)),
                    ],
                  ),
                ),
                Text(heroSubtitle,maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(color:Theme.of(c).colorScheme.onSurfaceVariant,fontSize:12,fontWeight:FontWeight.w500)),
              ])),
              IconButton(onPressed:()=>Navigator.pushNamed(c,'/notifications-settings'),icon:ValueListenableBuilder<bool>(valueListenable:unreadNotificationNotifier,builder:(_,u,__)=>Badge(isLabelVisible:u,child:const Icon(Icons.notifications_none_outlined)))),
              IconButton(onPressed:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>WishlistPage(onAdd:widget.onAdd))),icon:const Icon(Icons.favorite_border)),
              IconButton(onPressed:widget.onOpenCart,icon:Badge(isLabelVisible:widget.cart.isNotEmpty,child:const Icon(Icons.shopping_cart_outlined))),
            ]),
            InkWell(onTap:changeLocation,borderRadius:BorderRadius.circular(14),child:Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:11),decoration:BoxDecoration(color:Theme.of(c).colorScheme.surface,borderRadius:BorderRadius.circular(16),border:Border.all(color:Theme.of(c).colorScheme.outlineVariant)),child:Row(children:[const Icon(Icons.location_on_outlined,size:20,color:green),const SizedBox(width:8),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Deliver to',style:TextStyle(fontSize:10,color:Colors.grey)),Text(location,maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(fontWeight:FontWeight.w800,color:Theme.of(c).colorScheme.onSurface))])),const Text('Change',style:TextStyle(color:green,fontWeight:FontWeight.w800))]))),
            const SizedBox(height:10),
            TextField(controller:searchController,style:const TextStyle(fontSize:14),decoration:InputDecoration(hintText:'Search for products, brands and more',prefixIcon:const Icon(Icons.search),suffixIcon:IconButton(onPressed:listening?speech.stop:voice,icon:Icon(listening?Icons.mic:Icons.mic_none,color:listening?Colors.red:green)),filled:true,fillColor:Theme.of(c).colorScheme.surface,border:OutlineInputBorder(borderRadius:BorderRadius.circular(14),borderSide:BorderSide(color:Theme.of(c).colorScheme.outlineVariant))),onChanged:(v)=>setState(()=>search=v)),
            const SizedBox(height:10),
            StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(
              stream:FirebaseFirestore.instance.collection('settings').doc('delivery').snapshots(),
              builder:(context,deliverySnap){
                final ds={..._defaultDeliverySettings,...(deliverySnap.data?.data()??<String,dynamic>{})};
                final sub=widget.cart.values.fold<num>(0,(sum,item)=>sum+item.product.price*item.qty);
                final threshold=deliveryNum(ds,'freeScheduledThreshold',499).toDouble();
                final offerEnabled=deliveryBool(ds,'specialOfferEnabled',false);
                return Column(children:[
                  if(offerEnabled)
                    Card(child:ListTile(leading:const Icon(Icons.local_offer_outlined,color:green),title:Text((ds['specialOfferTitle']??'Just for you').toString(),style:const TextStyle(fontWeight:FontWeight.w900)),subtitle:Text((ds['specialOfferMessage']??'More scheduled delivery slots are available today.').toString()))),
                  if(widget.cart.isNotEmpty)
                    Card(color:AllwaysColors.primarySoft,child:Padding(padding:const EdgeInsets.all(12),child:Row(children:[
                      const Icon(Icons.local_shipping_outlined,color:green),
                      const SizedBox(width:8),
                      Expanded(child:Text(sub>=threshold?'FREE scheduled delivery unlocked!':'Add ₹'+(threshold-sub).ceil().toString()+' more to get FREE scheduled delivery',style:const TextStyle(fontWeight:FontWeight.w800))),
                    ]))),
                ]);
              },
            ),
            const SizedBox(height:12),
            StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(
              stream:FirebaseFirestore.instance.collection('settings').doc('banners').snapshots(),
              builder:(context,bannerSnap){
                final raw=bannerSnap.data?.data()?['imageUrls'];
                final urls=raw is List?raw.map((e)=>e.toString()).where((e)=>e.isNotEmpty).take(7).toList():<String>[];
                if(urls.isEmpty)return Container(height:150,padding:const EdgeInsets.all(18),decoration:BoxDecoration(color:const Color(0xFFE7F7EE),borderRadius:BorderRadius.circular(18)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(heroTitle,style:const TextStyle(fontSize:23,fontWeight:FontWeight.w900)),const SizedBox(height:6),Text(heroSubtitle),const Spacer(),Text(deliveryText,style:const TextStyle(color:green,fontWeight:FontWeight.w900))]));
                return SizedBox(height:160,child:ClipRRect(borderRadius:BorderRadius.circular(18),child:Stack(fit:StackFit.expand,children:[Image.network(urls[bannerIndex%urls.length],fit:BoxFit.cover,errorBuilder:(_,__,___)=>Container(color:const Color(0xFFE7F7EE))),Container(decoration:const BoxDecoration(gradient:LinearGradient(begin:Alignment.bottomCenter,end:Alignment.topCenter,colors:[Colors.black54,Colors.transparent]))),Positioned(left:16,right:16,bottom:14,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(heroTitle,style:const TextStyle(color:Colors.white,fontSize:22,fontWeight:FontWeight.w900)),Text(deliveryText,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w700))]))])));
              },
            ),
            const SizedBox(height:14),
            if(showCategories) ...[const Text('Shop by category',style:TextStyle(fontSize:20,fontWeight:FontWeight.w900)),const SizedBox(height:10),SizedBox(height:92,child:ListView.separated(scrollDirection:Axis.horizontal,itemCount:cs.length,separatorBuilder:(_,__)=>const SizedBox(width:8),itemBuilder:(_,i)=>categoryChip(c,cs[i]))),const SizedBox(height:16)],
            if(widget.loading)const Padding(padding:EdgeInsets.all(40),child:Center(child:CircularProgressIndicator()))
            else if(widget.error!=null)InfoCard(title:'Could not load inventory',detail:'Pull down to retry. Details: '+widget.error!)
            else if(searched.isEmpty)InfoCard(title:'No items found',detail:widget.products.isEmpty?'No products were returned by the catalog. Pull down to retry.':'Try another search or category. ('+widget.products.length.toString()+' products loaded)')
            else ...[
              if(showOffers)productSection(c,'Top offers',searched),
              if(showPopular)productSection(c,'Popular Near You',searched.skip(showOffers?4:0).take(4).toList()),
              for(final s in sections)
                if(s!='Popular Near You')
                  productSection(c,s,searched.where((p)=>p.category.trim().toLowerCase()==s.trim().toLowerCase()).toList()),
            ],
          ]),
        );
      },
    );
  }
}

class CategoryProductsPage extends StatelessWidget{
  final String category;
  final List<Product> products;
  final void Function(Product) onAdd;
  final Map<String,CartItem> cart;
  final void Function(String,int) onQty;
  final Set<String> wishlistIds;
  final Future<void> Function(Product) onWishlist;
  const CategoryProductsPage({super.key,required this.category,required this.products,required this.onAdd,required this.cart,required this.onQty,required this.wishlistIds,required this.onWishlist});

  @override
  Widget build(BuildContext context){
    return Scaffold(
      appBar:AppBar(title:Text(category)),
      body:products.isEmpty?const Center(child:Text('No products in this category yet.')):GridView.builder(
        padding:const EdgeInsets.all(12),
        itemCount:products.length,
        gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:2,crossAxisSpacing:10,mainAxisSpacing:10,childAspectRatio:.62),
        itemBuilder:(context,i){
          final p=products[i],item=cart[p.id],liked=wishlistIds.contains(p.id);
          return Card(clipBehavior:Clip.antiAlias,child:Padding(padding:const EdgeInsets.all(9),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Stack(children:[
              Container(height:150,width:double.infinity,alignment:Alignment.center,decoration:BoxDecoration(color:Theme.of(context).colorScheme.surfaceContainerHighest,borderRadius:BorderRadius.circular(14)),child:Text(p.icon,style:const TextStyle(fontSize:60))),
              Positioned(right:0,top:0,child:IconButton(onPressed:()=>onWishlist(p),icon:Icon(liked?Icons.favorite:Icons.favorite_border,color:Colors.red))),
            ]),
            const SizedBox(height:7),
            Text(p.name,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w900)),
            Text(p.category,style:const TextStyle(color:Colors.grey,fontSize:12)),
            Text('₹'+p.price.toString(),style:const TextStyle(fontSize:17,fontWeight:FontWeight.w900)),
            const Spacer(),
            if(item==null)
              SizedBox(width:double.infinity,height:38,child:FilledButton(onPressed:p.stock>0?()=>onAdd(p):null,child:const Text('Add')))
            else
              Container(height:38,decoration:BoxDecoration(border:Border.all(color:Theme.of(context).colorScheme.primary),borderRadius:BorderRadius.circular(20)),child:Row(children:[
                Expanded(child:IconButton(visualDensity:VisualDensity.compact,padding:EdgeInsets.zero,onPressed:()=>onQty(p.id,item.qty-1),icon:const Icon(Icons.remove,size:18))),
                Expanded(child:Center(child:Text(item.qty.toString(),style:const TextStyle(fontWeight:FontWeight.w900)))),
                Expanded(child:IconButton(visualDensity:VisualDensity.compact,padding:EdgeInsets.zero,onPressed:()=>onQty(p.id,item.qty+1),icon:const Icon(Icons.add,size:18))),
              ])),
          ])));
        },
      ),
    );
  }
}

class _AutoBannerCarousel extends StatefulWidget {
  final List<String> urls;
  final double height;
  const _AutoBannerCarousel({required this.urls, this.height = 165});
  @override State<_AutoBannerCarousel> createState() => _AutoBannerCarouselState();
}

class _AutoBannerCarouselState extends State<_AutoBannerCarousel> {
  late final PageController controller;
  Timer? timer;
  int index = 0;

  @override
  void initState() {
    super.initState();
    controller = PageController();
    _restartTimer();
  }

  void _restartTimer() {
    timer?.cancel();
    if (widget.urls.length > 1) {
      timer = Timer.periodic(const Duration(seconds: 4), (_) {
        if (!mounted || !controller.hasClients) return;
        final next = (index + 1) % widget.urls.length;
        controller.animateToPage(next, duration: const Duration(milliseconds: 450), curve: Curves.easeInOut);
      });
    }
  }

  @override
  void didUpdateWidget(covariant _AutoBannerCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.urls.length != oldWidget.urls.length) _restartTimer();
  }

  @override
  void dispose() {
    timer?.cancel();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      SizedBox(
        height: widget.height,
        child: PageView.builder(
          controller: controller,
          itemCount: widget.urls.length,
          onPageChanged: (v) => setState(() => index = v),
          itemBuilder: (context, i) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: LayoutBuilder(
                builder: (context, constraints) => Image.network(
                  cloudinaryImageUrl(widget.urls[i], width: constraints.maxWidth, height: widget.height),
                  fit: BoxFit.cover, width: double.infinity,
                  errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image_outlined)),
                ),
              ),
            ),
          ),
        ),
      ),
      if (widget.urls.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: 7),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(widget.urls.length, (i) => AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == index ? 18 : 6,
              height: 6,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                color: i == index ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant,
              ),
            )),
          ),
        ),
    ]);
  }
}

class ProductScreen extends StatelessWidget{
  final Product product; final VoidCallback onAdd; final bool liked; final VoidCallback onWishlist;
  const ProductScreen({super.key,required this.product,required this.onAdd,required this.liked,required this.onWishlist});
  @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:Text(product.name),actions:[IconButton(onPressed:onWishlist,icon:Icon(liked?Icons.favorite:Icons.favorite_border,color:Colors.red))]),body:ListView(padding:const EdgeInsets.all(20),children:[
    CircleAvatar(radius:54,child:Text(product.icon,style:const TextStyle(fontSize:44))),const SizedBox(height:20),
    Text(product.name,style:const TextStyle(fontSize:28,fontWeight:FontWeight.w900)),const SizedBox(height:8),Text(product.category,style:const TextStyle(color:Colors.grey)),
    if(product.brand.isNotEmpty)Text(product.brand,style:const TextStyle(color:Colors.grey)),const SizedBox(height:14),
    Text('₹'+product.price.toString(),style:const TextStyle(fontSize:24,fontWeight:FontWeight.w800)),const SizedBox(height:14),
    Text(product.description.isEmpty?'No description available.':product.description),const SizedBox(height:22),
    FilledButton.icon(onPressed:product.stock>0?onAdd:null,icon:const Icon(Icons.shopping_cart),label:Text(product.stock>0?'Add to cart':'Unavailable')),
  ]));
}

class CartScreen extends StatefulWidget{
  final Map<String,CartItem> cart;final List<Map<String,dynamic>> addresses;final void Function(String,int) onQty;final Future<void> Function(String,String,String,String,double?,double?,String,DateTime?) onPlace;
  const CartScreen({super.key,required this.cart,required this.addresses,required this.onQty,required this.onPlace});
  State<CartScreen> createState()=>_CartScreenState();
}
class _CartScreenState extends State<CartScreen>{
  final n=TextEditingController(),p=TextEditingController(),a=TextEditingController(),note=TextEditingController();bool placing=false,locating=false;double? selectedLatitude,selectedLongitude;Map<String,dynamic> deliverySettings={..._defaultDeliverySettings};String deliveryType='instant';DateTime? scheduledFor;
  @override void initState(){super.initState();loadSettings();}
  Future<void> loadSettings() async { final s=await loadDeliverySettings(); if(mounted)setState(()=>deliverySettings=s); }
  @override void dispose(){n.dispose();p.dispose();a.dispose();note.dispose();super.dispose();}
  void use(Map<String,dynamic> x){n.text=(x['name']??'').toString();p.text=(x['phone']??'').toString();a.text=(x['address']??'').toString();final lat=x['latitude']??x['lat'];final lng=x['longitude']??x['lng'];selectedLatitude=lat is num?lat.toDouble():double.tryParse((lat??'').toString());selectedLongitude=lng is num?lng.toDouble():double.tryParse((lng??'').toString());setState((){});}
  Future<void> useCurrentLocation() async {
    setState(()=>locating=true);
    try{
      if(!await Geolocator.isLocationServiceEnabled()){
        msg('Please turn on Location/GPS and try again.');
        return;
      }
      var permission=await Geolocator.checkPermission();
      if(permission==LocationPermission.denied){
        permission=await Geolocator.requestPermission();
      }
      if(permission==LocationPermission.denied||permission==LocationPermission.deniedForever){
        msg('Location permission was not granted. Please enter your address manually.');
        return;
      }
      final pos=await Geolocator.getCurrentPosition(
        locationSettings:const LocationSettings(accuracy:LocationAccuracy.high),
      ).timeout(const Duration(seconds:10));
      selectedLatitude=pos.latitude;
      selectedLongitude=pos.longitude;
      try{
        final marks=await placemarkFromCoordinates(pos.latitude,pos.longitude);
        if(marks.isNotEmpty){
          final x=marks.first;
          final parts=[
            x.street,
            x.subLocality,
            x.thoroughfare,
          ].whereType<String>()
           .where((v)=>v.trim().isNotEmpty)
           .map((v)=>v.trim())
           .toList();
          if(parts.isEmpty){
            final fallback=[
              x.locality,
              x.subAdministrativeArea,
              x.administrativeArea,
              x.postalCode,
            ].whereType<String>()
             .where((v)=>v.trim().isNotEmpty)
             .map((v)=>v.trim())
             .toList();
            parts.addAll(fallback);
          }
          a.text=parts.toSet().join(', ');
        }
      }catch(_){
        // Geocoding is isolated so a geocoder failure never reaches the
        // general location catch block.
      }
      if(a.text.trim().isEmpty){
        a.text='Latitude: '+pos.latitude.toString()+
            ', Longitude: '+pos.longitude.toString();
      }
      msg('Current location added. Please add your house number or landmark if needed.');
    }catch(e){
      if(e is TimeoutException){
        msg('Location request timed out after 10 seconds. GPS may be slow; please try again or enter the address manually.');
      }else{
        msg('Could not get your current location: '+e.toString());
      }
    }finally{
      if(mounted)setState(()=>locating=false);
    }
  }
  void msg(String text){if(!mounted)return;ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(text)));}
  Future<void> pickScheduledTime() async {
    if(!deliveryBool(deliverySettings,'scheduledEnabled',true)||DateTime.now().isAfter(scheduledCutoffNow(deliverySettings)))return;
    final now=DateTime.now();
    final date=await showDatePicker(context:context,firstDate:DateTime(now.year,now.month,now.day),lastDate:DateTime(now.year,now.month,now.day+7),initialDate:scheduledFor??now);
    if(date==null||!mounted)return;
    final time=await showTimePicker(context:context,initialTime:scheduledFor!=null?TimeOfDay.fromDateTime(scheduledFor!):TimeOfDay.fromDateTime(now.add(const Duration(hours:2))));
    if(time==null||!mounted)return;
    setState(()=>scheduledFor=DateTime(date.year,date.month,date.day,time.hour,time.minute));
  }

  Widget build(BuildContext c){
    final sub=widget.cart.values.fold<num>(0,(sum,item)=>sum+item.product.price*item.qty);
    final threshold=deliveryNum(deliverySettings,'freeScheduledThreshold',499).toDouble();
    final centerLat=deliveryNum(deliverySettings,'pilotCenterLat',0).toDouble();
    final centerLng=deliveryNum(deliverySettings,'pilotCenterLng',0).toDouble();
    final distanceKm=(centerLat!=0&&centerLng!=0&&selectedLatitude!=null&&selectedLongitude!=null)
        ?Geolocator.distanceBetween(selectedLatitude!,selectedLongitude!,centerLat,centerLng)/1000
        :null;
    final km=distanceKm==null?0:chargeableKm(distanceKm);
    final scheduledFree=sub>=threshold;
    final scheduledFee=scheduledFree?0:km*deliveryNum(deliverySettings,'scheduledPerKm',11);
    final instantFee=deliveryNum(deliverySettings,'instantBaseFee',35)+km*deliveryNum(deliverySettings,'instantPerKm',11);
    final scheduleAllowed=deliveryBool(deliverySettings,'scheduledEnabled',true)&&DateTime.now().isBefore(scheduledCutoffNow(deliverySettings));
    final fee=deliveryType=='scheduled'?scheduledFee:instantFee;
    final grand=sub+fee;
    final dark=Theme.of(c).brightness==Brightness.dark;
    return Scaffold(
      backgroundColor:dark?const Color(0xFF121014):AllwaysColors.background,
      appBar:AppBar(
        title:const Text('Cart',style:TextStyle(fontWeight:FontWeight.w900)),
        actions:[IconButton(onPressed:widget.cart.isEmpty?null:()=>showDialog<void>(
          context:c,
          builder:(d)=>AlertDialog(
            title:const Text('Clear cart?'),
            content:const Text('Remove all items from your cart?'),
            actions:[
              TextButton(onPressed:()=>Navigator.pop(d),child:const Text('Keep')),
              FilledButton(onPressed:(){for(final item in List<CartItem>.from(widget.cart.values))widget.onQty(item.product.id,-item.qty);Navigator.pop(d);},child:const Text('Clear')),
            ],
          ),
        ),icon:const Icon(Icons.delete_outline))],
      ),
      body:widget.cart.isEmpty
        ? Center(child:Padding(padding:const EdgeInsets.all(28),child:AllwaysCard(
            color:dark?const Color(0xFF1C191D):Colors.white,
            child:Column(mainAxisSize:MainAxisSize.min,children:[
              const Icon(Icons.shopping_bag_outlined,size:54,color:AllwaysColors.primary),
              const SizedBox(height:12),
              const Text('Your cart is empty',style:TextStyle(fontSize:20,fontWeight:FontWeight.w900)),
              const SizedBox(height:6),
              const Text('Add products from Shop and they will appear here.',textAlign:TextAlign.center,style:TextStyle(color:AllwaysColors.muted)),
              const SizedBox(height:16),
              FilledButton(onPressed:()=>Navigator.pop(c),child:const Text('Continue Shopping')),
            ]),
          )))
        : ListView(
            padding:const EdgeInsets.fromLTRB(14,8,14,24),
            children:[
              ...widget.cart.values.map((x)=>Padding(
                padding:const EdgeInsets.only(bottom:10),
                child:AllwaysCard(
                  child:Row(children:[
                    Container(width:68,height:68,decoration:BoxDecoration(color:AllwaysColors.primarySoft,borderRadius:BorderRadius.circular(16)),alignment:Alignment.center,child:Text(x.product.icon,style:const TextStyle(fontSize:34))),
                    const SizedBox(width:12),
                    Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                      Text(x.product.name,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w900,fontSize:15)),
                      const SizedBox(height:3),
                      Text('₹${x.product.price.toStringAsFixed(x.product.price%1==0?0:2)}',style:const TextStyle(color:AllwaysColors.muted)),
                      const SizedBox(height:8),
                      Container(height:34,decoration:BoxDecoration(color:AllwaysColors.primarySoft,borderRadius:BorderRadius.circular(17)),child:Row(mainAxisSize:MainAxisSize.min,children:[
                        IconButton(visualDensity:VisualDensity.compact,onPressed:()=>widget.onQty(x.product.id,-1),icon:const Icon(Icons.remove,size:18,color:AllwaysColors.primary)),
                        SizedBox(width:28,child:Center(child:Text('${x.qty}',style:const TextStyle(fontWeight:FontWeight.w900)))),
                        IconButton(visualDensity:VisualDensity.compact,onPressed:()=>widget.onQty(x.product.id,1),icon:const Icon(Icons.add,size:18,color:AllwaysColors.primary)),
                      ])),
                    ])),
                    const SizedBox(width:8),
                    Text('₹${(x.product.price*x.qty).toStringAsFixed((x.product.price*x.qty)%1==0?0:2)}',style:const TextStyle(fontWeight:FontWeight.w900,fontSize:16)),
                  ]),
                ),
              )),
              const SizedBox(height:4),
              if(sub<threshold)
                AllwaysCard(
                  child:Row(children:[
                    const Icon(Icons.local_offer_outlined,color:AllwaysColors.primary),
                    const SizedBox(width:10),
                    Expanded(child:Text('Add ₹'+(threshold-sub).ceil().toString()+' more to unlock FREE scheduled delivery',style:const TextStyle(fontWeight:FontWeight.w800))),
                  ]),
                )
              else
                const AllwaysCard(child:Row(children:[
                  Icon(Icons.celebration_outlined,color:AllwaysColors.primary),
                  SizedBox(width:10),
                  Expanded(child:Text('You unlocked FREE scheduled delivery!',style:TextStyle(fontWeight:FontWeight.w800))),
                ])),
              const SizedBox(height:10),
              AllwaysCard(
                child:Column(children:[
                  const Align(alignment:Alignment.centerLeft,child:Text('Delivery option',style:TextStyle(fontSize:17,fontWeight:FontWeight.w900))),
                  const SizedBox(height:8),
                  Row(children:[
                    Expanded(child:ChoiceChip(label:const Text('Instant'),selected:deliveryType=='instant',onSelected:deliveryBool(deliverySettings,'instantEnabled',true)?(_){setState(()=>deliveryType='instant');}:null)),
                    const SizedBox(width:8),
                    Expanded(child:ChoiceChip(label:Text(scheduleAllowed?'Scheduled':'Scheduled closed'),selected:deliveryType=='scheduled',onSelected:scheduleAllowed?(_){setState(()=>deliveryType='scheduled');}:null)),
                  ]),
                  const SizedBox(height:8),
                  if(deliveryType=='scheduled')
                    Row(children:[
                      Expanded(child:OutlinedButton.icon(onPressed:pickScheduledTime,icon:const Icon(Icons.schedule),label:Text(scheduledFor==null?'Choose date & time':MaterialLocalizations.of(context).formatMediumDate(scheduledFor!)+' • '+MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(scheduledFor!))))),
                    ]),
                  if(deliveryType=='scheduled'&&scheduledFor!=null)
                    Align(alignment:Alignment.centerLeft,child:Text(scheduledFree?'Scheduled delivery: FREE':'Scheduled delivery: ₹'+scheduledFee.toStringAsFixed(0)+' • '+km.toString()+' km',style:const TextStyle(color:AllwaysColors.muted))),
                  if(deliveryType=='instant')
                    Align(alignment:Alignment.centerLeft,child:Text('Instant delivery: ₹'+instantFee.toStringAsFixed(0)+' • base ₹'+deliveryNum(deliverySettings,'instantBaseFee',35).toStringAsFixed(0)+' + '+km.toString()+' km',style:const TextStyle(color:AllwaysColors.muted))),
                ]),
              ),
              const SizedBox(height:10),
              AllwaysCard(
                child:Column(children:[
                  const Align(alignment:Alignment.centerLeft,child:Text('Bill Details',style:TextStyle(fontSize:17,fontWeight:FontWeight.w900))),
                  const SizedBox(height:12),
                  Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('Items Total'),Text('₹'+sub.toStringAsFixed(0))]),
                  const SizedBox(height:8),
                  Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('Delivery Fee'),Text(fee==0?'FREE':'₹'+fee.toStringAsFixed(0),style:const TextStyle(fontWeight:FontWeight.w700))]),
                  const Divider(height:22),
                  Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('You Pay',style:TextStyle(fontWeight:FontWeight.w900)),Text('₹'+grand.toStringAsFixed(0),style:const TextStyle(fontWeight:FontWeight.w900,fontSize:19))]),
                  const SizedBox(height:8),
                  const Align(alignment:Alignment.centerLeft,child:Text('Cash on Delivery (COD)',style:TextStyle(color:AllwaysColors.muted))),
                ]),
              ),
              const SizedBox(height:12),
              const Text('Delivery details',style:TextStyle(fontSize:20,fontWeight:FontWeight.w900)),
              const SizedBox(height:10),
              if(widget.addresses.isNotEmpty) ...[
                ...widget.addresses.map((x)=>AllwaysCard(
                  padding:const EdgeInsets.symmetric(horizontal:12,vertical:4),
                  child:ListTile(
                    contentPadding:EdgeInsets.zero,
                    onTap:()=>use(x),
                    leading:const Icon(Icons.location_on_outlined,color:AllwaysColors.primary),
                    title:Text((x['name']??'Saved address').toString(),style:const TextStyle(fontWeight:FontWeight.w800)),
                    subtitle:Text((x['address']??'').toString(),maxLines:2,overflow:TextOverflow.ellipsis),
                    trailing:const Icon(Icons.chevron_right),
                  ),
                )),
                const SizedBox(height:8),
              ],
              TextField(controller:n,decoration:const InputDecoration(labelText:'Full name')),
              const SizedBox(height:9),
              TextField(controller:p,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'10-digit phone number')),
              const SizedBox(height:9),
              TextField(controller:a,maxLines:3,decoration:const InputDecoration(labelText:'Delivery address')),
              const SizedBox(height:6),
              OutlinedButton.icon(
                onPressed:locating?null:useCurrentLocation,
                icon:locating?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.my_location),
                label:Text(locating?'Getting location…':'Use current location'),
              ),
              const SizedBox(height:9),
              TextField(controller:note,maxLines:2,decoration:const InputDecoration(labelText:'Delivery note (optional)')),
              const SizedBox(height:14),
              SizedBox(height:52,child:FilledButton.icon(
                onPressed:placing?null:()async{
                  setState(()=>placing=true);
                  await widget.onPlace(n.text,p.text,a.text,note.text,selectedLatitude,selectedLongitude,deliveryType,scheduledFor);
                  if(mounted)setState(()=>placing=false);
                },
                style:FilledButton.styleFrom(backgroundColor:AllwaysColors.primary,foregroundColor:Colors.white,shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(18))),
                icon:const Icon(Icons.shopping_bag_outlined),
                label:Text(placing?'Placing order…':'Place Order (COD)',style:const TextStyle(fontWeight:FontWeight.w900)),
              )),
            ],
          ),
    );
  }
}

class OrdersPage extends StatefulWidget {
  final User? user;
  final Future<void> Function(String) onCancel;
  final Future<void> Function(List<Map<String,dynamic>>) onReorder;
  const OrdersPage({super.key, required this.user, required this.onCancel, required this.onReorder});

  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  String _filter = 'All';
  final List<String> _filters = ['All', 'Out for delivery', 'Reorder'];

  DateTime _createdAt(Map<String, dynamic> o) {
    final value = o['createdAt'];
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    return DateTime.tryParse((o['time'] ?? '').toString()) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  String _dateLabel(Map<String, dynamic> o) {
    final d = _createdAt(o);
    if (d.millisecondsSinceEpoch == 0) return 'Date unavailable';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return 'Delivered on ${months[d.month-1]} ${d.day}';
  }

  Color _statusColor(String status) {
    final s = status.toLowerCase();
    if (s.contains('delivered')) return const Color(0xFF2E7D32);
    if (s.contains('out for delivery') || s.contains('ready')) return const Color(0xFFEF6C00);
    if (s.contains('cancel')) return const Color(0xFFC62828);
    if (s.contains('confirm') || s.contains('prepar') || s.contains('new')) return const Color(0xFF1565C0);
    return Colors.grey;
  }

  Widget _statusChip(String status) {
    final color = _statusColor(status);
    final isCancel = status.toLowerCase().contains('cancel');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isCancel ? const Color(0xFFFFEBEE) : color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(status, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _productThumbs(BuildContext context, List items) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final list = items.take(3).toList();
    final extra = items.length - list.length;
    if (list.isEmpty) {
      return Container(
        width: 62,
        height: 62,
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF24262C) : const Color(0xFFF7F5F6),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(Icons.inventory_2_outlined, color: dark ? const Color(0xFFB8BBC3) : Colors.grey),
      );
    }
    return SizedBox(
      width: 62,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < list.length; i++) ...[
            _singleThumb(context, list[i]),
            if (i < list.length - 1 || extra > 0) const SizedBox(height: 6),
          ],
          if (extra > 0)
            Container(
              width: 62,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF2C1B23) : const Color(0xFFFFE8EF),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '+$extra more',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: dark ? const Color(0xFFFF9CBD) : const Color(0xFFB3134A),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _singleThumb(BuildContext context, dynamic item) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final m = item is Map ? Map<String,dynamic>.from(item) : <String,dynamic>{};
    final img = (m['imageUrl'] ?? m['image'] ?? '').toString();
    final fallback = m['icon']?.toString() ?? '';
    final background = dark ? const Color(0xFF24262C) : const Color(0xFFF7F5F6);
    final border = dark ? const Color(0xFF343740) : const Color(0xFFE8E6E8);
    return Container(
      width: 62,
      height: 62,
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(14), border: Border.all(color: border)),
      child: img.startsWith('http')
          ? ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: Image.network(
                img,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Icon(Icons.inventory_2_outlined, color: dark ? const Color(0xFFB8BBC3) : Colors.grey),
              ),
            )
          : Center(
              child: Text(
                fallback.isNotEmpty ? fallback : '🛍️',
                style: const TextStyle(fontSize: 22),
              ),
            ),
    );
  }

  Widget _itemSummary(BuildContext context, List items) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final names = items.take(3).map((item) {
      final m = item is Map ? Map<String,dynamic>.from(item) : <String,dynamic>{};
      return (m['name'] ?? 'Item').toString();
    }).toList();
    if (names.isEmpty) return Text('Order items', style: TextStyle(color: dark ? const Color(0xFFA7A9B0) : const Color(0xFF666971), fontSize: 13));
    final remaining = items.length - names.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final name in names)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: dark ? const Color(0xFFF0F1F3) : const Color(0xFF33353D),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (remaining > 0)
          Text(
            '+$remaining more items',
            style: TextStyle(
              color: dark ? const Color(0xFFFF9CBD) : const Color(0xFFB3134A),
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
      ],
    );
  }

  bool _matchesFilter(Map<String, dynamic> o) {
    final status = (o['status'] ?? '').toString().toLowerCase();
    switch (_filter) {
      case 'Out for delivery':
        return status.contains('out for delivery') || status.contains('assigned') || status.contains('picked');
      case 'Reorder':
        return status.contains('delivered');
      case 'All':
      default:
        return true;
    }
  }

  void _openOrderDetails(BuildContext context, String orderId, Map<String, dynamic> order) {
    try {
      Navigator.pushNamed(context, '/order-details', arguments: {'orderId': orderId});
    } catch (_) {
      // Fallback: show a simple details dialog
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Order #${orderId.length > 8 ? orderId.substring(0, 8) : orderId}'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Status: ${order['status'] ?? '-'}', style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text('Total: ₹${order['total'] ?? order['grandTotal'] ?? 0}'),
                if ((order['items'] is List) && (order['items'] as List).isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('Items:', style: TextStyle(fontWeight: FontWeight.w700)),
                  ...(order['items'] as List).take(10).map((it) {
                    final m = it is Map ? Map<String,dynamic>.from(it) : <String,dynamic>{};
                    return Text('• ${m['name'] ?? 'Item'} × ${m['qty'] ?? 1}');
                  }),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext c) {
    final dark = Theme.of(c).brightness == Brightness.dark;
    if (widget.user == null) {
      return const Scaffold(body: Center(child: InfoCard(title: 'Your orders', detail: 'Sign in to place and track your ALLways orders.')));
    }
    return Scaffold(
      backgroundColor: dark ? const Color(0xFF101114) : const Color(0xFFFAF7F8),
      appBar: AppBar(
        backgroundColor: dark ? const Color(0xFF101114) : Colors.white,
        elevation: 0.5,
        centerTitle: true,
        title: Text('My Orders', style: TextStyle(color: dark ? const Color(0xFFF5F5F7) : Colors.black87, fontWeight: FontWeight.w800, fontSize: 18)),
        iconTheme: IconThemeData(color: dark ? const Color(0xFFF5F5F7) : Colors.black87),
      ),
      body: Column(
        children: [
          Container(
            color: dark ? const Color(0xFF101114) : Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _filters.map((f) {
                  final selected = _filter == f;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f, style: TextStyle(
                        fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                        fontSize: 13,
                        color: selected ? Colors.white : (dark ? const Color(0xFFD9DBE1) : Colors.black87),
                      )),
                      selected: selected,
                      selectedColor: dark ? const Color(0xFFB3134A) : Colors.black87,
                      backgroundColor: dark ? const Color(0xFF191B20) : Colors.white,
                      side: BorderSide(color: selected ? (dark ? const Color(0xFFB3134A) : Colors.black87) : (dark ? const Color(0xFF3A3D45) : const Color(0xFFDDDDDD))),
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('orders')
                  .where('customerId', isEqualTo: widget.user!.uid)
                  .snapshots(),
              builder: (context, primarySnapshot) {
                if (primarySnapshot.hasError) {
                  return Center(child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Could not load orders.\\n'+primarySnapshot.error.toString(), textAlign: TextAlign.center, style: TextStyle(color: dark ? const Color(0xFFA7A9B0) : Colors.black54)),
                  ));
                }
                if (!primarySnapshot.hasData) return const Center(child: CircularProgressIndicator());
                return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .collection('orders')
                      .where('customerUid', isEqualTo: widget.user!.uid)
                      .snapshots(),
                  builder: (context, legacySnapshot) {
                    final merged = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
                    for (final d in primarySnapshot.data!.docs) merged[d.id] = d;
                    for (final d in (legacySnapshot.data?.docs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[])) {
                      merged[d.id] = d;
                    }
                    return _buildList(merged.values.toList());
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    // Sort by createdAt desc client-side (avoids composite index requirement)
    final sorted = List<QueryDocumentSnapshot<Map<String, dynamic>>>.from(docs);
    sorted.sort((a, b) {
      final da = _createdAt(a.data());
      final db = _createdAt(b.data());
      return db.compareTo(da);
    });

    final list = sorted.where((d) => _matchesFilter(d.data())).toList();

    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _filter == 'All' ? 'No orders yet.' : 'No orders in "$_filter".',
            style: const TextStyle(color: Colors.black54, fontSize: 15),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final d = list[i];
        final o = d.data();
        final status = (o['status'] ?? 'New Order').toString();
        final rawItems = o['items'];
        final items = rawItems is List ? rawItems : <dynamic>[];
        final total = o['total'] ?? o['grandTotal'] ?? 0;
        final canCancel = ['new order', 'confirmed', 'preparing'].any((s) => status.toLowerCase().contains(s));
        final canReorder = status.toLowerCase().contains('delivered') && items.isNotEmpty;

        final dark = Theme.of(context).brightness == Brightness.dark;

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          elevation: 0,
          color: dark ? const Color(0xFF191B20) : const Color(0xFFFFF5F7),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: dark ? const Color(0xFF303239) : const Color(0xFFEEEEEE))),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _openOrderDetails(context, o['id']?.toString() ?? d.id, o),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _productThumbs(context, items),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              status.toLowerCase().contains('delivered') ? _dateLabel(o) : status,
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                                color: status.toLowerCase().contains('delivered') ? Colors.black87 : _statusColor(status),
                              ),
                            ),
                            const SizedBox(height: 4),
                            _itemSummary(context, items),
                            const SizedBox(height: 6),
                            Text('₹$total', style: TextStyle(color: dark ? const Color(0xFFF0F1F3) : const Color(0xFF24262C), fontWeight: FontWeight.w800, fontSize: 15)),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, color: dark ? const Color(0xFF8D9098) : Colors.black38),
                    ],
                  ),
                  if (canReorder) ...[
                    const SizedBox(height: 12),
                    const Divider(height: 1),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () => widget.onReorder(
                          items.whereType<Map>().map((x) => Map<String,dynamic>.from(x)).toList(),
                        ),
                        icon: const Icon(Icons.replay, size: 18),
                        label: const Text('Reorder'),
                      ),
                    ),
                  ],
                  if (canCancel) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: dark ? const Color(0xFFFF8A8A) : const Color(0xFFC62828),
                          side: BorderSide(color: dark ? const Color(0xFF6B3030) : const Color(0xFFEF9A9A)),
                        ),
                        onPressed: () => _confirmCancel(context, o['id']?.toString() ?? d.id),
                        child: const Text('Cancel order'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmCancel(BuildContext c, String id) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: c,
      builder: (_) => AlertDialog(
        title: const Text('Cancel order?'),
        content: TextField(controller: reason, maxLines: 3, decoration: const InputDecoration(labelText: 'Reason for cancellation')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep order')),
          FilledButton(onPressed: () => Navigator.pop(c, reason.text.trim().isNotEmpty), child: const Text('Cancel order')),
        ],
      ),
    ) ?? false;
    final clean = reason.text.trim();
    reason.dispose();
    if (ok) await widget.onCancel(id + '||' + clean);
  }
}


class StatusView extends StatelessWidget{final String status;const StatusView({super.key,required this.status});Widget build(BuildContext c){
  const s=['New Order','Confirmed','Preparing','Out for delivery','Delivered'];final i=s.indexOf(status)<0?0:s.indexOf(status);
  return Column(children:[for(int x=0;x<s.length;x++)ListTile(dense:true,contentPadding:EdgeInsets.zero,leading:Icon(x<=i?Icons.check_circle:Icons.radio_button_unchecked,color:x<=i?Colors.green:Colors.grey),title:Text(s[x]))]);
}}


class TravelPage extends StatefulWidget {
  const TravelPage({super.key});
  @override State<TravelPage> createState()=>_TravelPageState();
}

class _TravelPageState extends State<TravelPage> {
  bool loadingAvailability=true;
  int bikeCount=0,autoCount=0,carCount=0;

  @override void initState(){super.initState();_loadAvailability();}

  Future<void> _loadAvailability() async {
    try {
      if(!await Geolocator.isLocationServiceEnabled()){if(mounted)setState(()=>loadingAvailability=false);return;}
      var permission=await Geolocator.checkPermission();
      if(permission==LocationPermission.denied)permission=await Geolocator.requestPermission();
      if(permission==LocationPermission.denied||permission==LocationPermission.deniedForever){if(mounted)setState(()=>loadingAvailability=false);return;}
      final me=await Geolocator.getCurrentPosition(locationSettings:const LocationSettings(accuracy:LocationAccuracy.medium));
      final snap=await FirebaseFirestore.instance.collection('ridePartners').where('status',isEqualTo:'online').get();
      int b=0,a=0,car=0;
      final now=DateTime.now();
      for(final d in snap.docs){
        final x=d.data();
        if((x['approvalStatus']??'').toString().toLowerCase()!='approved'||x['availableForRides']!=true)continue;
        final lat=x['carrierLat']??x['driverLat']; final lng=x['carrierLng']??x['driverLng'];
        final la=lat is num?lat.toDouble():double.tryParse((lat??'').toString());
        final ln=lng is num?lng.toDouble():double.tryParse((lng??'').toString());
        if(la==null||ln==null||la==0||ln==0)continue;
        final ts=x['carrierLocationUpdatedAt']??x['lastLocationAt'];
        final updated=ts is Timestamp?ts.toDate():null;
        if(updated!=null&&now.difference(updated).inMinutes>3)continue;
        if(Geolocator.distanceBetween(me.latitude,me.longitude,la,ln)>7000)continue;
        final type=(x['vehicleType']??'bike').toString().toLowerCase();
        if(type=='auto')a++;else if(type=='car')car++;else b++;
      }
      if(mounted){setState((){bikeCount=b;autoCount=a;carCount=car;loadingAvailability=false;});}
    }catch(_){if(mounted)setState(()=>loadingAvailability=false);}
  }

  Widget _availabilityCard(BuildContext context)=>Card(elevation:0,margin:const EdgeInsets.only(bottom:16),child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Row(children:[const Expanded(child:Text('Nearby availability',style:TextStyle(fontSize:17,fontWeight:FontWeight.w900))),IconButton(onPressed:loadingAvailability?null:_loadAvailability,icon:const Icon(Icons.refresh))]),
    Text(loadingAvailability?'Checking nearby approved partners…':(bikeCount+autoCount+carCount==0?'No approved partners nearby right now':'Partners available within 7 km'),style:const TextStyle(color:Colors.grey,fontSize:12)),
    const SizedBox(height:10),
    Row(children:[Expanded(child:_vehicleAvailability('Bike',bikeCount,Icons.two_wheeler,Colors.deepPurple)),const SizedBox(width:8),Expanded(child:_vehicleAvailability('Auto',autoCount,Icons.local_taxi_outlined,Colors.black)),const SizedBox(width:8),Expanded(child:_vehicleAvailability('Car',carCount,Icons.directions_car_outlined,Colors.blueGrey))]),
  ])));
  Widget _vehicleAvailability(String label,int count,IconData icon,Color color)=>Container(padding:const EdgeInsets.symmetric(vertical:11,horizontal:8),decoration:BoxDecoration(color:color.withOpacity(.07),borderRadius:BorderRadius.circular(14)),child:Column(children:[Icon(icon,size:21,color:color),const SizedBox(height:4),Text(count.toString(),style:const TextStyle(fontSize:18,fontWeight:FontWeight.w900)),Text(label,style:const TextStyle(fontSize:11,color:Colors.grey))]));
  Widget _rideCard(BuildContext context,{required IconData icon,required String title,required String subtitle,required Color color,required VoidCallback onTap})=>Card(
    elevation:0,margin:const EdgeInsets.only(bottom:12),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(18)),
    child:InkWell(onTap:onTap,borderRadius:BorderRadius.circular(18),child:Padding(padding:const EdgeInsets.all(16),child:Row(children:[
      Container(width:58,height:58,decoration:BoxDecoration(color:color,borderRadius:BorderRadius.circular(16)),child:Icon(icon,color:Colors.white,size:30)),
      const SizedBox(width:14),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:const TextStyle(fontSize:18,fontWeight:FontWeight.w900)),const SizedBox(height:4),Text(subtitle,style:const TextStyle(color:Colors.grey,height:1.3))])),const Icon(Icons.chevron_right),
    ]))));
  @override Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.fromLTRB(16,12,16,110),children:[
    Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('Travel',style:const TextStyle(fontSize:30,fontWeight:FontWeight.w900)),Text('Move around your city with simple, upfront rides.',style:const TextStyle(color:Colors.grey))])),const Icon(Icons.location_on_outlined,size:30)]),
    const SizedBox(height:14),_availabilityCard(context),
    Container(padding:const EdgeInsets.all(18),decoration:BoxDecoration(color:const Color(0xFFFFC928),borderRadius:BorderRadius.circular(22)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Row(children:[Icon(Icons.two_wheeler,size:34),SizedBox(width:10),Text('ALLways Mobility',style:TextStyle(fontSize:23,fontWeight:FontWeight.w900))]),const SizedBox(height:8),const Text('Fast local bike and auto rides with upfront estimates, nearby partner matching and live tracking.',style:TextStyle(height:1.35)),
      const SizedBox(height:14),FilledButton(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const OnDemandRidePage(rideType:'bike'))),style:FilledButton.styleFrom(backgroundColor:Colors.black,foregroundColor:Colors.white),child:const Text('Book a bike ride')),
    ])),
    const SizedBox(height:16),const Text('Ride with ALLways',style:TextStyle(fontSize:21,fontWeight:FontWeight.w900)),const SizedBox(height:10),
    _rideCard(context,icon:Icons.two_wheeler,title:'Bike ride',subtitle:'Quick point-to-point ride. Upfront estimate and live tracking after acceptance.',color:const Color(0xFF5B1ACF),onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const OnDemandRidePage(rideType:'bike')))),
    _rideCard(context,icon:Icons.local_taxi_outlined,title:'Auto ride',subtitle:'Affordable local auto ride with partner acceptance and live tracking.',color:const Color(0xFF111111),onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const OnDemandRidePage(rideType:'auto')))),
    _rideCard(context,icon:Icons.directions_car_outlined,title:'Book a vehicle',subtitle:'Choose from 25 vehicle categories. Owners set price and booking terms.',color:const Color(0xFF303030),onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const VehicleBookingPage()))),
    Card(elevation:0,color:const Color(0xFFF6F6F6),child:const Padding(padding:EdgeInsets.all(14),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Icon(Icons.shield_outlined),SizedBox(width:10),Expanded(child:Text('Safety tools, calling, cancellation and live location are available during an active ride.',style:TextStyle(color:Colors.grey,height:1.35)))]))),
  ]);
}
class ProfilePage extends StatefulWidget{
  final User? user; final List<Map<String,dynamic>> addresses; final VoidCallback onLogin;
  final Future<void> Function() onReload; final Future<void> Function(String) onDelete; final Future<void> Function(String) onCancel; final Future<void> Function(List<Map<String,dynamic>>) onReorder; final void Function(Product) onAdd;
  const ProfilePage({super.key,required this.user,required this.addresses,required this.onLogin,required this.onReload,required this.onDelete,required this.onCancel,required this.onReorder,required this.onAdd});
  @override State<ProfilePage> createState()=>_ProfilePageState();
}
class _ProfilePageState extends State<ProfilePage>{
  Future<void> _checkForUpdate(BuildContext c) async {
    try{
      final r=await http.get(Uri.parse(updateManifestUrl)).timeout(const Duration(seconds:8));
      if(!c.mounted)return;
      if(r.statusCode==200){
        final d=jsonDecode(r.body);
        if(d is Map&&(d['version']??'').toString().isNotEmpty){
          ScaffoldMessenger.of(c).showSnackBar(SnackBar(content:Text('Latest version: '+d['version'].toString())));
          return;
        }
      }
      ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content:Text('Could not check for updates.')));
    }catch(_){
      if(c.mounted)ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content:Text('Could not check for updates.')));
    }
  }

  Future<void> _deleteAccount(BuildContext c) async {
    final confirmation=TextEditingController();
    final confirmed=await showDialog<bool>(
      context:c,
      builder:(dialogContext)=>AlertDialog(
        title:const Text('Delete Account'),
        content:Column(mainAxisSize:MainAxisSize.min,children:[
          const Text('This permanently deletes your ALLways account and customer profile data. This action cannot be undone.'),
          const SizedBox(height:12),
          TextField(controller:confirmation,decoration:const InputDecoration(labelText:'Type DELETE to confirm')),
        ]),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dialogContext,false),child:const Text('Cancel')),
          FilledButton(onPressed:()=>Navigator.pop(dialogContext,confirmation.text.trim()=='DELETE'),child:const Text('Delete')),
        ],
      ),
    )??false;
    confirmation.dispose();
    if(!confirmed)return;
    try{
      final u=FirebaseAuth.instance.currentUser;
      if(u==null)return;
      try{
        await u.delete();
      }on FirebaseAuthException catch(e){
        if(e.code!='requires-recent-login')rethrow;
        final providers=u.providerData.map((p)=>p.providerId).toList();
        if(providers.contains('google.com')){
          final gs=GoogleSignIn.instance;
          if(!gs.supportsAuthenticate())throw Exception('Please sign in again before deleting your account.');
          final gu=await gs.authenticate();
          final token=gu.authentication.idToken;
          if(token==null||token.isEmpty)throw Exception('Google re-authentication failed.');
          await u.reauthenticateWithCredential(GoogleAuthProvider.credential(idToken:token));
        }else{
          final password=await showDialog<String>(context:c,builder:(d){
            final controller=TextEditingController();
            return AlertDialog(
              title:const Text('Confirm password'),
              content:TextField(controller:controller,obscureText:true,decoration:const InputDecoration(labelText:'Password')),
              actions:[
                TextButton(onPressed:()=>Navigator.pop(d),child:const Text('Cancel')),
                FilledButton(onPressed:()=>Navigator.pop(d,controller.text),child:const Text('Continue')),
              ],
            );
          });
          if(password==null||password.isEmpty)throw Exception('Account deletion cancelled.');
          await u.reauthenticateWithCredential(EmailAuthProvider.credential(email:u.email??'',password:password));
        }
        await u.delete();
      }
      await FirebaseFirestore.instance.collection('customers').doc(u.uid).delete().catchError((_){});
      await FirebaseAuth.instance.signOut();
    }catch(e){
      if(c.mounted)ScaffoldMessenger.of(c).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));
    }
  }

  Future<void> _chooseAppearance(BuildContext c) async {
    await showDialog<void>(
      context:c,
      builder:(dialogContext)=>ValueListenableBuilder<ThemeMode>(
        valueListenable:themeNotifier,
        builder:(context,mode,_)=>AlertDialog(
          title:const Text('Appearance'),
          content:Column(mainAxisSize:MainAxisSize.min,children:[
            RadioListTile<ThemeMode>(title:const Text('Light'),value:ThemeMode.light,groupValue:mode,onChanged:(v)async{if(v==null)return;themeNotifier.value=v;final p=await SharedPreferences.getInstance();await p.setString('allways_theme_mode','light');if(dialogContext.mounted)Navigator.pop(dialogContext);}),
            RadioListTile<ThemeMode>(title:const Text('Dark'),value:ThemeMode.dark,groupValue:mode,onChanged:(v)async{if(v==null)return;themeNotifier.value=v;final p=await SharedPreferences.getInstance();await p.setString('allways_theme_mode','dark');if(dialogContext.mounted)Navigator.pop(dialogContext);}),
            RadioListTile<ThemeMode>(title:const Text('System'),value:ThemeMode.system,groupValue:mode,onChanged:(v)async{if(v==null)return;themeNotifier.value=v;final p=await SharedPreferences.getInstance();await p.setString('allways_theme_mode','system');if(dialogContext.mounted)Navigator.pop(dialogContext);}),
          ]),
        ),
      ),
    );
  }

  Widget _menuCard(BuildContext c,{required IconData icon,required String title,required String subtitle,required VoidCallback onTap,bool danger=false,bool showDot=false}){
    final scheme=Theme.of(c).colorScheme;
    final accent=danger?scheme.error:scheme.primary;
    return Card(
      margin:const EdgeInsets.symmetric(horizontal:16,vertical:6),
      elevation:0,
      color:scheme.surface,
      shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(16)),
      child:InkWell(
        onTap:onTap,
        borderRadius:BorderRadius.circular(16),
        child:Padding(
          padding:const EdgeInsets.symmetric(horizontal:14,vertical:14),
          child:Row(children:[
            Container(
              width:48,height:48,
              decoration:BoxDecoration(color:danger?scheme.errorContainer:scheme.primaryContainer,borderRadius:BorderRadius.circular(14)),
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  Icon(icon,color:danger?scheme.onErrorContainer:scheme.onPrimaryContainer),
                if(showDot) Positioned(right:-3,top:-3,child:Container(width:10,height:10,decoration:BoxDecoration(color:Colors.green,shape:BoxShape.circle,border:Border.all(color:scheme.surface,width:2)))),
              ]),
            ),
            const SizedBox(width:14),
            Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Text(title,style:TextStyle(fontSize:16,fontWeight:FontWeight.w800,color:danger?scheme.error:null)),
              const SizedBox(height:3),
              Text(subtitle,style:TextStyle(color:scheme.onSurfaceVariant,fontSize:13)),
            ])),
            Icon(Icons.chevron_right,color:accent),
          ]),
        ),
      ),
    );
  }
  // Language preference is reactive through languageNotifier so visible labels update immediately.
  Future<void> _chooseLanguage(BuildContext c) async {
    final prefs=await SharedPreferences.getInstance();
    final current=prefs.getString('allways_language')??'English';
    const languages=['English','Hindi','Hinglish','Bhojpuri','Awadhi'];
    await showDialog<void>(
      context:c,
      builder:(dialogContext)=>AlertDialog(
        title:const Text('Language'),
        content:Column(mainAxisSize:MainAxisSize.min,children:[
          for(final language in languages)
            RadioListTile<String>(
              value:language,
              groupValue:current,
              title:Text(language),
              onChanged:(value) async {
                if(value==null)return;
                await prefs.setString('allways_language',value);
                languageNotifier.value=value;
                if(dialogContext.mounted)Navigator.pop(dialogContext);
                if(c.mounted)ScaffoldMessenger.of(c).showSnackBar(SnackBar(content:Text('Language preference saved: '+value)));
              },
            ),
        ]),
      ),
    );
  }

  Future<void> _openNotifications(BuildContext c) async {
    await markNotificationsRead();
    if(!c.mounted)return;
    await showModalBottomSheet<void>(context:c,isScrollControlled:true,showDragHandle:true,builder:(_)=>const NotificationsPage());
  }

  @override Widget build(BuildContext c){
    final u=widget.user;
    if(u==null)return Center(child:FilledButton(onPressed:widget.onLogin,child:const Text('Sign in / Sign up')));
    return ListView(
      padding:const EdgeInsets.only(top:12,bottom:24),
      children:[
        Padding(padding:const EdgeInsets.fromLTRB(16,0,16,6),child:Text(tr('Profile'),style:const TextStyle(fontSize:28,fontWeight:FontWeight.w900))),
        Card(
          margin:const EdgeInsets.symmetric(horizontal:16,vertical:6),
          elevation:0,
          shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(16)),
          child:Padding(padding:const EdgeInsets.all(16),child:Row(children:[
            CircleAvatar(radius:30,child:Text((u.displayName??'A').trim().isEmpty?'A':(u.displayName??'A').trim()[0].toUpperCase())),
            const SizedBox(width:14),
            Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Text(u.displayName??'ALLways customer',style:const TextStyle(fontSize:18,fontWeight:FontWeight.w800)),
              const SizedBox(height:3),
              Text(u.email??'',style:TextStyle(color:Theme.of(c).colorScheme.onSurfaceVariant)),
            ])),
          ])),
        ),
        _menuCard(c,icon:Icons.receipt_long_outlined,title:'Orders',subtitle:'View and track your ALLways orders',onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>OrdersPage(user:u,onCancel:widget.onCancel,onReorder:widget.onReorder)))),
        _menuCard(c,icon:Icons.location_on_outlined,title:'Saved Addresses',subtitle:'Add, edit or manage your delivery addresses',onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>SavedAddressesPage(userId:u.uid,addresses:widget.addresses,onReload:widget.onReload,onDelete:widget.onDelete)))),
        _menuCard(c,icon:Icons.favorite_border,title:'Wishlist',subtitle:'Your saved products and favourites',onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>WishlistPage(onAdd:widget.onAdd)))),
        ValueListenableBuilder<bool>(valueListenable:unreadNotificationNotifier,builder:(_,unread,__)=>_menuCard(c,icon:Icons.notifications_outlined,title:tr('Notifications'),subtitle:'Alerts, order updates and push settings',showDot:unread,onTap:()=>_openNotifications(c))),
        _menuCard(c,icon:Icons.brightness_6_outlined,title:tr('Appearance'),subtitle:'Light, Dark or System theme',onTap:()=>_chooseAppearance(c)),
        _menuCard(c,icon:Icons.language_outlined,title:tr('Language'),subtitle:'Choose your preferred app language',onTap:()=>_chooseLanguage(c)),
        _menuCard(c,icon:Icons.share_outlined,title:tr('Share ALLways'),subtitle:'Share ALLways with friends and family',onTap:()=>SharePlus.instance.share(ShareParams(text:'Try ALLways — Closer to You, Always. Download ALLways 1.5.0: '+shareApkUrl))),
        _menuCard(c,icon:Icons.system_update_outlined,title:tr('Check for Updates'),subtitle:'Check for the latest ALLways version',onTap:()=>_checkForUpdate(c)),
        _menuCard(c,icon:Icons.privacy_tip_outlined,title:'Privacy Policy',subtitle:'How ALLways handles your information',onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>const PrivacyPolicyPage()))),
        _menuCard(c,icon:Icons.logout_outlined,title:tr('Log Out'),subtitle:'Sign out of your ALLways account',danger:true,onTap:()=>FirebaseAuth.instance.signOut()),
        _menuCard(c,icon:Icons.delete_outline,title:'Delete Account',subtitle:'Permanently delete your ALLways account',danger:true,onTap:()=>_deleteAccount(c)),
        const SizedBox(height:12),
        const Text('ALLways • Closer to You, Always',textAlign:TextAlign.center,style:TextStyle(color:Colors.grey)),
      ],
    );
  }

}

Future<void> markNotificationsRead() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('allways_notifications') ?? <String>[];
    final updated = raw.map((entry) {
      try {
        final decoded = jsonDecode(entry);
        if (decoded is Map) {
          final item = Map<String,dynamic>.from(decoded);
          item['read'] = true;
          return jsonEncode(item);
        }
      } catch (_) {}
      return entry;
    }).toList();
    await prefs.setStringList('allways_notifications', updated);
  } catch (_) {}
  unreadNotificationNotifier.value = false;
}

class NotificationsPage extends StatefulWidget{
  const NotificationsPage({super.key});
  @override State<NotificationsPage> createState()=>_NotificationsPageState();
}
class _NotificationsPageState extends State<NotificationsPage>{
  bool enabled=true,loading=true; List<Map<String,dynamic>> notifications=[];
  final Map<String,bool> prefs=<String,bool>{'orderUpdates':true,'deliveryUpdates':true,'travelUpdates':true,'offers':true,'announcements':true};
  String filter='All';
  @override void initState(){super.initState();_load();}

  Future<void> _load() async {try{final p=await SharedPreferences.getInstance();enabled=p.getBool('notifications_enabled')??p.getBool('allways_notifications_enabled')??true;for(final key in prefs.keys){prefs[key]=p.getBool('notification_'+key)??true;}final raw=p.getStringList('allways_notifications')??<String>[];notifications=raw.map((x){try{final d=jsonDecode(x);return d is Map?Map<String,dynamic>.from(d):<String,dynamic>{};}catch(_){return <String,dynamic>{};}}).where((x)=>x.isNotEmpty).toList();}catch(_){}if(mounted)setState(()=>loading=false);}
  Future<void> _savePreference(String key,bool value) async {prefs[key]=value;final p=await SharedPreferences.getInstance();await p.setBool('notification_'+key,value);final u=FirebaseAuth.instance.currentUser;if(u!=null){try{await FirebaseFirestore.instance.collection('fcmTokens').doc(u.uid).set({'notificationPreferences':Map<String,bool>.from(prefs),'notificationsEnabled':enabled,'updatedAt':FieldValue.serverTimestamp()},SetOptions(merge:true));}catch(_){}}if(mounted)setState((){});}
  Future<void> _toggle(bool value) async {try{if(value){final status=await FirebaseMessaging.instance.requestPermission(alert:true,badge:true,sound:true,provisional:false);if(status.authorizationStatus==AuthorizationStatus.denied){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Notification permission is disabled for ALLways.')));return;}await FirebaseMessaging.instance.subscribeToTopic('all_users');enabled=true;}else{await FirebaseMessaging.instance.unsubscribeFromTopic('all_users');enabled=false;}final p=await SharedPreferences.getInstance();await p.setBool('notifications_enabled',enabled);await p.setBool('allways_notifications_enabled',enabled);final u=FirebaseAuth.instance.currentUser;if(u!=null)await FirebaseFirestore.instance.collection('fcmTokens').doc(u.uid).set({'uid':u.uid,'email':u.email??'','notificationsEnabled':enabled,'notificationPreferences':Map<String,bool>.from(prefs),'updatedAt':FieldValue.serverTimestamp()},SetOptions(merge:true));if(enabled){final token=await FirebaseMessaging.instance.getToken();if(token!=null&&u!=null){await FirebaseFirestore.instance.collection('fcmTokens').doc(u.uid).collection('tokens').doc(token).set({'uid':u.uid,'email':u.email??'','token':token,'notificationsEnabled':true,'notificationPreferences':Map<String,bool>.from(prefs),'updatedAt':FieldValue.serverTimestamp()},SetOptions(merge:true));await FirebaseFirestore.instance.collection('fcmTokens').doc(u.uid).set({'uid':u.uid,'email':u.email??'','token':token,'notificationsEnabled':true,'notificationPreferences':Map<String,bool>.from(prefs),'updatedAt':FieldValue.serverTimestamp()},SetOptions(merge:true));await p.setString('allways_fcm_token',token);}}}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Notification setting could not be saved: '+e.toString())));}if(mounted)setState((){});}
  Future<void> _markAllRead() async {try{final p=await SharedPreferences.getInstance();final raw=p.getStringList('allways_notifications')??<String>[];final updated=raw.map((x){try{final d=jsonDecode(x);if(d is Map){final m=Map<String,dynamic>.from(d);m['read']=true;return jsonEncode(m);}}catch(_){}return x;}).toList();await p.setStringList('allways_notifications',updated);unreadNotificationNotifier.value=false;await _load();}catch(_){}}
  Future<void> _clearHistory() async {final p=await SharedPreferences.getInstance();await p.remove('allways_notifications');unreadNotificationNotifier.value=false;if(mounted)setState(()=>notifications=[]);}
  String _time(dynamic value){final ms=value is num?value.toInt():int.tryParse(value?.toString()??'')??0;if(ms<=0)return'';final d=DateTime.fromMillisecondsSinceEpoch(ms);final diff=DateTime.now().difference(d);if(diff.inMinutes<1)return'Just now';if(diff.inHours<1)return diff.inMinutes.toString()+' min ago';if(diff.inDays<1)return diff.inHours.toString()+' hr ago';return d.day.toString().padLeft(2,'0')+'/'+d.month.toString().padLeft(2,'0')+'/'+d.year.toString();}
  bool _matches(Map<String,dynamic> n){if(filter=='All')return true;final type=(n['type']??'').toString().toLowerCase();if(filter=='Orders')return type.contains('order');if(filter=='Delivery')return type.contains('delivery');if(filter=='Travel')return type.contains('ride')||type.contains('vehicle')||type.contains('travel');if(filter=='Offers')return type.contains('offer')||type.contains('promotion');return true;}
  Widget _setting({required IconData icon,required String title,required String subtitle,required String key})=>SwitchListTile(contentPadding:const EdgeInsets.symmetric(horizontal:16,vertical:2),secondary:CircleAvatar(child:Icon(icon)),title:Text(title,style:const TextStyle(fontWeight:FontWeight.w800)),subtitle:Text(subtitle),value:enabled&&prefs[key]!,onChanged:enabled?(v)=>_savePreference(key,v):null);
  @override Widget build(BuildContext context){final visible=notifications.where(_matches).toList();return SafeArea(child:Column(children:[
    Padding(padding:const EdgeInsets.fromLTRB(16,6,12,4),child:Row(children:[const Icon(Icons.notifications_outlined,size:26),const SizedBox(width:10),const Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('Notifications',style:TextStyle(fontSize:22,fontWeight:FontWeight.w900)),Text('Stay updated with your ALLways activity',style:TextStyle(color:Colors.grey,fontSize:12))])),IconButton(onPressed:()=>Navigator.pop(context),icon:const Icon(Icons.close))])),
    Expanded(child:loading?const Center(child:CircularProgressIndicator()):ListView(padding:const EdgeInsets.fromLTRB(16,8,16,28),children:[
      Card(child:SwitchListTile(contentPadding:const EdgeInsets.fromLTRB(16,8,16,8),secondary:CircleAvatar(radius:24,child:Icon(enabled?Icons.notifications_active_outlined:Icons.notifications_off_outlined)),title:const Text('ALLways notifications',style:TextStyle(fontSize:17,fontWeight:FontWeight.w900)),subtitle:Text(enabled?'Notifications are enabled':'Notifications are turned off'),value:enabled,onChanged:_toggle)),
      const SizedBox(height:14),const Text('ORDER & DELIVERY',style:TextStyle(fontSize:12,fontWeight:FontWeight.w900,color:Colors.grey)),const SizedBox(height:6),
      Card(child:Column(children:[_setting(icon:Icons.receipt_long_outlined,title:'Order updates',subtitle:'Confirmation, preparation, delivery and completion',key:'orderUpdates'),const Divider(height:1),_setting(icon:Icons.local_shipping_outlined,title:'Delivery updates',subtitle:'Partner offers, acceptance and out-for-delivery alerts',key:'deliveryUpdates')])),
      const SizedBox(height:14),const Text('TRAVEL & OFFERS',style:TextStyle(fontSize:12,fontWeight:FontWeight.w900,color:Colors.grey)),const SizedBox(height:6),
      Card(child:Column(children:[_setting(icon:Icons.two_wheeler_outlined,title:'Travel & ride updates',subtitle:'Ride requests, acceptance and vehicle bookings',key:'travelUpdates'),const Divider(height:1),_setting(icon:Icons.local_offer_outlined,title:'Offers & promotions',subtitle:'Special offers and discounts from ALLways',key:'offers'),const Divider(height:1),_setting(icon:Icons.campaign_outlined,title:'ALLways announcements',subtitle:'Important service announcements and news',key:'announcements')])),
      const SizedBox(height:18),
      Row(children:[const Expanded(child:Text('NOTIFICATION HISTORY',style:TextStyle(fontSize:12,fontWeight:FontWeight.w900,color:Colors.grey))),TextButton(onPressed:notifications.isEmpty?null:_markAllRead,child:const Text('Mark all read')),TextButton(onPressed:notifications.isEmpty?null:_clearHistory,child:const Text('Clear'))]),
      SingleChildScrollView(scrollDirection:Axis.horizontal,child:Row(children:['All','Orders','Delivery','Travel','Offers'].map((x)=>Padding(padding:const EdgeInsets.only(right:6),child:ChoiceChip(label:Text(x),selected:filter==x,onSelected:(_)=>setState(()=>filter=x)))).toList())),
      const SizedBox(height:8),
      if(visible.isEmpty)Card(child:Padding(padding:const EdgeInsets.all(28),child:Column(children:[Icon(Icons.notifications_none,size:54,color:Theme.of(context).colorScheme.primary),const SizedBox(height:10),const Text('No notifications yet.',style:TextStyle(fontSize:17,fontWeight:FontWeight.w800)),const SizedBox(height:4),const Text('Your order, delivery and travel updates will appear here.',textAlign:TextAlign.center,style:TextStyle(color:Colors.grey))])))
      else ...visible.map((n){final title=(n['title']??'ALLways').toString(),body=(n['body']??'').toString(),time=_time(n['timestamp']),read=n['read']==true,type=(n['type']??'').toString().toLowerCase();return Card(color:read?null:Theme.of(context).colorScheme.primaryContainer,margin:const EdgeInsets.only(bottom:8),child:ListTile(leading:CircleAvatar(child:Icon(type.contains('delivery')?Icons.local_shipping_outlined:type.contains('ride')?Icons.two_wheeler_outlined:Icons.notifications_outlined)),title:Text(title,style:const TextStyle(fontWeight:FontWeight.w800)),subtitle:Text(body),trailing:time.isEmpty?null:Text(time,style:const TextStyle(fontSize:11,color:Colors.grey))));}),
      const SizedBox(height:12),Card(child:Padding(padding:const EdgeInsets.all(14),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[const Icon(Icons.info_outline),const SizedBox(width:10),const Expanded(child:Text('Live location updates are shown on the tracking map, not as repeated push notifications. This keeps alerts useful and reduces unnecessary network traffic.',style:TextStyle(color:Colors.grey,height:1.35)))]))),
    ])),
  ]));}
}

const vehicleCategories = <String>[
  'Motorcycle','Scooter','E-bike','Auto Rickshaw','E-Rickshaw','Hatchback','Sedan','SUV','MUV',
  'Luxury Car','Taxi / Cab','Tempo Traveller','Van','Mini Bus','Bus','Pickup Truck','Mini Truck (Tata Ace)',
  'Bolero Pickup','Goods Auto','Cargo Van','Tractor','Tractor Trolley','Trailer','Ambulance','Other / Enter manually',
];

class VehicleBookingPage extends StatefulWidget {
  const VehicleBookingPage({super.key});
  @override State<VehicleBookingPage> createState()=>_VehicleBookingPageState();
}

class _VehicleBookingPageState extends State<VehicleBookingPage> {
  StreamSubscription<QuerySnapshot<Map<String,dynamic>>>? _vehicleBookingSubscription;
  LiveLocationBroadcaster? _vehicleLocationBroadcaster;
  String? _broadcastingVehicleBookingId;

  @override
  void initState(){
    super.initState();
    final uid=FirebaseAuth.instance.currentUser?.uid;
    if(uid!=null){
      _vehicleBookingSubscription=FirebaseFirestore.instance.collection('vehicleBookings').where('ownerUid',isEqualTo:uid).snapshots().listen((snapshot) async {
        QueryDocumentSnapshot<Map<String,dynamic>>? active;
        for(final d in snapshot.docs){
          final status=(d.data()['status']??'').toString().toLowerCase();
          if(status!='rejected'&&status!='cancelled'&&status!='delivered'){active=d;break;}
        }
        if(active==null){
          await _vehicleLocationBroadcaster?.stop();
          _vehicleLocationBroadcaster=null;_broadcastingVehicleBookingId=null;
          return;
        }
        if(_broadcastingVehicleBookingId==active.id)return;
        await _vehicleLocationBroadcaster?.stop();
        final broadcaster=LiveLocationBroadcaster();
        if(!mounted)return;
        if(!await ensureBackgroundLocationDisclosure(context))return;
        final started=await broadcaster.start(collection:'vehicleBookings',docId:active.id,prefix:'owner',background:true);
        if(started){_vehicleLocationBroadcaster=broadcaster;_broadcastingVehicleBookingId=active.id;}
      });
    }
  }

  @override
  void dispose(){
    _vehicleBookingSubscription?.cancel();
    _vehicleLocationBroadcaster?.stop();
    super.dispose();
  }

  Future<void> _publishVehicle() async {
    final user=FirebaseAuth.instance.currentUser;
    if(user==null){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Please sign in first.')));return;}
    final name=TextEditingController(),phone=TextEditingController(),price=TextEditingController(),capacity=TextEditingController(),custom=TextEditingController(),village=TextEditingController(),landmark=TextEditingController(),pincode=TextEditingController();
    double? vehicleLatitude;
    double? vehicleLongitude;
    String category=vehicleCategories.first; bool negotiate=true; XFile? vehiclePhoto; bool uploading=false;
    try{
      final ok=await showDialog<bool>(context:context,builder:(dialogContext)=>StatefulBuilder(builder:(context,setDialogState)=>AlertDialog(
        title:const Text('List your vehicle'),
        content:SizedBox(width:420,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
          DropdownButtonFormField<String>(initialValue:category,decoration:const InputDecoration(labelText:'Vehicle category'),items:vehicleCategories.map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v){if(v!=null)setDialogState(()=>category=v);}),
          if(category=='Other / Enter manually')TextField(controller:custom,decoration:const InputDecoration(labelText:'Enter vehicle type')),
          TextField(controller:name,decoration:const InputDecoration(labelText:'Owner name')),
          TextField(controller:phone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'Mobile number')),
          const SizedBox(height:10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: uploading ? null : () async {
                final image = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 70, maxWidth: 600);
                if (image != null) setDialogState(() => vehiclePhoto = image);
              },
              icon: const Icon(Icons.camera_alt),
              label: Text(vehiclePhoto == null ? 'Upload vehicle photo' : 'Vehicle photo selected'),
            ),
          ),
          const Align(alignment:Alignment.centerLeft,child:Text('Vehicle photo is required.',style:TextStyle(color:Colors.grey,fontSize:12))),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: uploading ? null : () async {
                try {
                  if (!await Geolocator.isLocationServiceEnabled()) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Turn on GPS first.')));
                    return;
                  }
                  var permission=await Geolocator.checkPermission();
                  if(permission==LocationPermission.denied) permission=await Geolocator.requestPermission();
                  if(permission==LocationPermission.denied||permission==LocationPermission.deniedForever){
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location permission was not granted.')));
                    return;
                  }
                  final pos=await Geolocator.getCurrentPosition(locationSettings:const LocationSettings(accuracy:LocationAccuracy.high)).timeout(const Duration(seconds:10));
                  setDialogState((){vehicleLatitude=pos.latitude;vehicleLongitude=pos.longitude;});
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Current GPS location captured.')));
                } catch(e) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not capture GPS location: $e')));
                }
              },
              icon: const Icon(Icons.my_location),
              label: Text(vehicleLatitude==null?'Use current location':'Current location captured'),
            ),
          ),
          TextField(controller:village,decoration:const InputDecoration(labelText:'Village / Town / City Name')),
          TextField(controller:landmark,decoration:const InputDecoration(labelText:'Landmark / Main Road')),
          TextField(controller:pincode,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Pincode')),
          TextField(controller:capacity,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Seats / capacity')),
          TextField(controller:price,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Your price (₹)')),
          SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('Allow negotiation'),value:negotiate,onChanged:(v)=>setDialogState(()=>negotiate=v)),
          const Align(alignment:Alignment.centerLeft,child:Text('You choose the price. ALLways does not set a fixed vehicle-booking price.',style:TextStyle(color:Colors.grey,fontSize:12))),
        ]))),
        actions:[TextButton(onPressed:()=>Navigator.pop(dialogContext,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(dialogContext,true),child:const Text('Publish'))],
      )))??false;
      if(!ok)return;
      final cleanPhone=phone.text.replaceAll(RegExp(r'\D'),''); final cleanPrice=num.tryParse(price.text.trim())??0;
      if(name.text.trim().isEmpty||cleanPhone.length!=10||cleanPrice<=0||vehiclePhoto==null||village.text.trim().isEmpty||landmark.text.trim().isEmpty||pincode.text.trim().isEmpty){
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Enter owner name, valid 10-digit mobile number, price and upload a vehicle photo.')));return;
      }
      final type=category=='Other / Enter manually'?custom.text.trim():category;
      if(type.isEmpty){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Enter the vehicle type.')));return;}
      try {
        uploading = true;
        final vehiclePhotoUrl = await uploadImageToCloudinary(vehiclePhoto!, folder: 'vehicles/' + user.uid);
        await FirebaseFirestore.instance.collection('vehicles').add({
          'ownerUid':user.uid,'ownerName':name.text.trim(),'ownerPhone':cleanPhone,'category':type,
          'capacity':int.tryParse(capacity.text.trim())??0,'price':cleanPrice,'allowNegotiation':negotiate,
          'vehiclePhotoUrl':vehiclePhotoUrl,'status':'available','latitude':vehicleLatitude,'longitude':vehicleLongitude,'manual_location':{'villageTownCity':village.text.trim(),'landmarkMainRoad':landmark.text.trim(),'pincode':pincode.text.trim()},'createdAt':FieldValue.serverTimestamp()
        });
      } catch(e) {
        if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Vehicle photo upload failed: '+e.toString())));
        return;
      }
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Vehicle published successfully.')));
    }finally{name.dispose();phone.dispose();price.dispose();capacity.dispose();custom.dispose();village.dispose();landmark.dispose();pincode.dispose();}
  }

  Future<void> _book(DocumentSnapshot<Map<String,dynamic>> doc,{required bool negotiate}) async {
    final user=FirebaseAuth.instance.currentUser;
    if(user==null){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Please sign in first.')));return;}
    final d=doc.data()??{};
    await FirebaseFirestore.instance.collection('vehicleBookings').add({'vehicleId':doc.id,'ownerUid':d['ownerUid'],'ownerName':d['ownerName'],'ownerPhone':d['ownerPhone'],'customerUid':user.uid,'customerName':user.displayName??'ALLways customer','customerEmail':user.email??'','category':d['category'],'listedPrice':d['price'],'mode':negotiate?'negotiation':'book','status':'Booked','createdAt':FieldValue.serverTimestamp()});
    if(!mounted)return;
    await showDialog<void>(context:context,builder:(c)=>AlertDialog(
      title:Text(negotiate?'Booking request sent':'Vehicle booked'),
      content:Text(negotiate?'The vehicle owner can now contact you to negotiate and confirm the final price.':'Booking confirmed. You can now contact the vehicle owner.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Done')),FilledButton.icon(onPressed:()=>_call(d['ownerPhone']?.toString()??''),icon:const Icon(Icons.call),label:const Text('Contact owner'))],
    ));
  }

  Future<void> _call(String phone) async { if(phone.trim().isEmpty)return; await launchUrl(Uri.parse('tel:'+phone.trim())); }

  @override Widget build(BuildContext context){
    final user=FirebaseAuth.instance.currentUser;
    return Scaffold(appBar:AppBar(title:const Text('Book vehicle')),body:StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(
      stream:FirebaseFirestore.instance.collection('vehicles').where('status',isEqualTo:'available').snapshots(),
      builder:(context,snapshot){
        final docs=snapshot.data?.docs??const <QueryDocumentSnapshot<Map<String,dynamic>>>[];
        return ListView(padding:const EdgeInsets.fromLTRB(16,8,16,28),children:[
          Card(child:ListTile(leading:const Icon(Icons.add_business_outlined),title:const Text('Offer your vehicle',style:TextStyle(fontWeight:FontWeight.w900)),subtitle:const Text('Vehicle owners choose their own price and can allow negotiation.'),trailing:const Icon(Icons.chevron_right),onTap:user==null?null:_publishVehicle)),
          if(user!=null)
            StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(
              stream:FirebaseFirestore.instance.collection('vehicleBookings').where('ownerUid',isEqualTo:user.uid).snapshots(),
              builder:(context,snapshot){
                final docs=snapshot.data?.docs??const <QueryDocumentSnapshot<Map<String,dynamic>>>[];
                final active=docs.where((d){final st=(d.data()['status']??'').toString().toLowerCase();return st!='rejected'&&st!='cancelled'&&st!='delivered';}).toList();
                if(active.isEmpty)return const SizedBox.shrink();
                return Card(child:ExpansionTile(
                  leading:const Icon(Icons.assignment_outlined),
                  title:const Text('Vehicle booking requests',style:TextStyle(fontWeight:FontWeight.w900)),
                  children:active.take(10).map((doc){final d=doc.data();return ListTile(
                    title:Text((d['customerName']??'Customer').toString(),style:const TextStyle(fontWeight:FontWeight.w800)),
                    subtitle:Text((d['status']??'Booking').toString()+' • ₹'+(d['listedPrice']??0).toString()),
                    trailing:OutlinedButton(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>LiveTrackingScreen(collection:'vehicleBookings',docId:doc.id,title:'Live vehicle tracking',mode:'vehicle',readOnly:true)),),child:const Text('Track')),
                  );}).toList(),
                ));
              },
            ),
          const SizedBox(height:10),const Text('Available vehicles',style:TextStyle(fontSize:20,fontWeight:FontWeight.w900)),const SizedBox(height:8),
          if(snapshot.hasError)const InfoCard(title:'Could not load vehicles',detail:'Please try again later.'),
          if(!snapshot.hasData)const Padding(padding:EdgeInsets.all(20),child:Center(child:CircularProgressIndicator())),
          if(snapshot.hasData&&docs.isEmpty)const InfoCard(title:'No vehicles listed yet',detail:'Vehicle owners can publish a vehicle from “Offer your vehicle”.'),
          ...docs.map((doc){final d=doc.data();final allow=d['allowNegotiation']==true;return Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Row(children:[const Icon(Icons.directions_car_outlined),const SizedBox(width:10),Expanded(child:Text((d['category']??'Vehicle').toString(),style:const TextStyle(fontSize:18,fontWeight:FontWeight.w900))),Text('₹'+(d['price']??0).toString(),style:const TextStyle(fontSize:18,fontWeight:FontWeight.w900))]),
            const SizedBox(height:6),Text('Owner: '+(d['ownerName']??'').toString()+(d['capacity']!=null&&d['capacity'].toString()!='0'?' • Capacity: '+d['capacity'].toString():'')),
            const SizedBox(height:4),Text(allow?'Owner allows negotiation':'Fixed owner price',style:const TextStyle(color:Colors.grey)),const SizedBox(height:10),
            Row(children:[Expanded(child:FilledButton(onPressed:()=>_book(doc,negotiate:false),child:const Text('Book'))),if(allow)...[const SizedBox(width:8),Expanded(child:OutlinedButton(onPressed:()=>_book(doc,negotiate:true),child:const Text('Book & negotiate')))]])
          ])));}),
          const SizedBox(height:14),TravelBookingsSection(type:'vehicle'),const SizedBox(height:14),const Text('25 popular vehicle categories',style:TextStyle(fontSize:18,fontWeight:FontWeight.w900)),const SizedBox(height:8),
          Wrap(spacing:8,runSpacing:8,children:vehicleCategories.map((x)=>Chip(label:Text(x))).toList()),
        ]);
      },
    ));
  }
}

class OnDemandRidePage extends StatefulWidget {
  final String rideType;
  const OnDemandRidePage({super.key,this.rideType='bike'});
  @override State<OnDemandRidePage> createState()=>_OnDemandRidePageState();
}

class _OnDemandRidePageState extends State<OnDemandRidePage> {
  late String rideType;
  @override void initState(){super.initState();rideType=widget.rideType=='auto'?'auto':'bike';}
  Position? pickupPosition;

  Future<Position?> _currentPosition() async {
    try{
      if(!await Geolocator.isLocationServiceEnabled())return null;
      var p=await Geolocator.checkPermission();
      if(p==LocationPermission.denied)p=await Geolocator.requestPermission();
      if(p==LocationPermission.denied||p==LocationPermission.deniedForever)return null;
      return Geolocator.getCurrentPosition(locationSettings:const LocationSettings(accuracy:LocationAccuracy.high)).timeout(const Duration(seconds:10));
    }catch(_){return null;}
  }

  Future<void> _requestRide() async {
    final user=FirebaseAuth.instance.currentUser;
    if(user==null){
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Please sign in first.')));
      return;
    }
    final destination=TextEditingController();
    try{
      final pickup=await _currentPosition();
      if(pickup==null){
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Turn on location to request a ride.')));
        return;
      }
      pickupPosition=pickup;
      double? dLat,dLng;
      final ok=await showModalBottomSheet<bool>(
        context:context,
        isScrollControlled:true,
        builder:(sheetContext)=>Padding(
          padding:EdgeInsets.only(left:16,right:16,top:8,bottom:MediaQuery.of(sheetContext).viewInsets.bottom+16),
          child:StatefulBuilder(builder:(c,setSheetState)=>Column(
            mainAxisSize:MainAxisSize.min,
            children:[
              const SizedBox(height:4),
              Row(children:[const Icon(Icons.two_wheeler_outlined),const SizedBox(width:10),const Expanded(child:Text('Book a Bike / Auto Ride',style:TextStyle(fontSize:20,fontWeight:FontWeight.w900))),IconButton(onPressed:()=>Navigator.pop(c,false),icon:const Icon(Icons.close))]),
              const SizedBox(height:12),

              ListTile(
                dense:true,
                leading:const Icon(Icons.my_location,color:Colors.green),
                title:const Text('Pickup'),
                subtitle:Text('Current location • '+pickup.latitude.toStringAsFixed(5)+', '+pickup.longitude.toStringAsFixed(5)),
              ),
              TextField(
                controller:destination,
                textInputAction:TextInputAction.done,
                decoration:const InputDecoration(prefixIcon:Icon(Icons.location_on_outlined),labelText:'Where to?',hintText:'Enter destination'),
              ),
              const SizedBox(height:12),
              SizedBox(width:double.infinity,child:FilledButton.icon(
                onPressed:()=>Navigator.pop(c,true),
                icon:const Icon(Icons.search),
                label:const Text('See fare & find partner'),
              )),
            ],
          )),
        ),
      )??false;
      if(!ok)return;
      if(destination.text.trim().isEmpty){
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Enter your destination.')));
        return;
      }

      try{
        final places=await locationFromAddress(destination.text.trim());
        if(places.isNotEmpty){dLat=places.first.latitude;dLng=places.first.longitude;}
      }catch(_){}
      String pickupAddress='Current location';
      try {
        final marks=await placemarkFromCoordinates(pickup.latitude,pickup.longitude);
        if(marks.isNotEmpty){final m=marks.first;pickupAddress=[m.name,m.street,m.locality,m.subLocality].where((x)=>x!=null&&x!.trim().isNotEmpty).map((x)=>x!.trim()).toSet().join(', ');}
      }catch(_){}
      final distance=dLat==null||dLng==null?0.0:Geolocator.distanceBetween(pickup.latitude,pickup.longitude,dLat,dLng)/1000.0;
      final base=rideType=='bike'?20.0:30.0;
      final perKm=rideType=='bike'?8.0:12.0;
      final minimum=rideType=='bike'?30.0:40.0;
      final estimate=distance<=0?minimum:math.max(minimum,base+(distance*perKm));

      final customerSnap=await FirebaseFirestore.instance.collection('customers').doc(user.uid).get();
      final customerData=customerSnap.data()??<String,dynamic>{};
      final customerPhone=(user.phoneNumber??customerData['phone']??customerData['mobileNumber']??'').toString();

      final confirm=await showDialog<bool>(
        context:context,
        builder:(c)=>AlertDialog(
          title:Text(rideType=='bike'?'Bike ride':'Auto ride'),
          content:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('Pickup: Current location'),
            Text('Drop: '+destination.text.trim()),
            const SizedBox(height:8),
            Text(distance>0?'Distance: '+distance.toStringAsFixed(1)+' km':'Distance will be updated after pickup'),
            const SizedBox(height:8),
            Text('Estimated fare: ₹'+estimate.toStringAsFixed(0),style:const TextStyle(fontSize:18,fontWeight:FontWeight.w900)),
            const SizedBox(height:8),
            const Text('Partner must accept before the ride starts. You can track and call the partner after acceptance.',style:TextStyle(color:Colors.grey,fontSize:12)),
          ]),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Cancel')),
            FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Confirm ride')),
          ],
        ),
      )??false;
      if(!confirm)return;

      final ref=await FirebaseFirestore.instance.collection('autoRideRequests').add({
        'customerUid':user.uid,
        'customerName':user.displayName??customerData['name']??'ALLways customer',
        'customerPhone':customerPhone,
        'rideType':rideType,
        'status':'searching',
        'pickupLatitude':pickup.latitude,
        'pickupLongitude':pickup.longitude,
        'pickupAddress': pickupAddress,
        'destination':destination.text.trim(),
        'destinationAddress':destination.text.trim(),
        'destinationLatitude':dLat,
        'destinationLongitude':dLng,
        'distanceKm':distance,
        'estimatedFare':estimate,
        'rejectedBy':<String>[],
        'createdAt':FieldValue.serverTimestamp(),
        'updatedAt':FieldValue.serverTimestamp(),
      });
      if(mounted)Navigator.push(context,MaterialPageRoute(builder:(_)=>OnDemandRideTrackingPage(requestId:ref.id,rideType:rideType)));
    }finally{destination.dispose();}
  }

  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:Text(rideType=='bike'?'Book Bike Ride':'Book Auto Ride')),
    body:ListView(padding:const EdgeInsets.fromLTRB(16,10,16,28),children:[
      Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(children:[const Icon(Icons.two_wheeler_outlined),const SizedBox(width:10),const Expanded(child:Text('On-demand rides',style:TextStyle(fontSize:21,fontWeight:FontWeight.w900)))]),
        const SizedBox(height:8),
        Text(rideType=='bike'?'Choose your destination, see an upfront bike fare estimate and request an available bike partner.':'Choose your destination, see an upfront auto fare estimate and request an available auto partner.',style:const TextStyle(color:Colors.grey,height:1.35)),
        const SizedBox(height:14),

        SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:_requestRide,icon:const Icon(Icons.search),label:Text('Find a '+(rideType=='bike'?'Bike':'Auto')))),
      ]))),
      const SizedBox(height:12),
      Card(child:ListTile(
        leading:const Icon(Icons.location_searching),
        title:const Text('Live tracking'),
        subtitle:const Text('After acceptance, customer and partner can see each other moving on the map. The partner marker uses a moving bike/vehicle icon.'),
      )),
      Card(child:ListTile(
        leading:const Icon(Icons.call_outlined),
        title:const Text('Contact after acceptance'),
        subtitle:const Text('Customer and partner can call each other after the ride is accepted.'),
      )),
      Card(child:ListTile(
        leading:const Icon(Icons.cancel_outlined),
        title:const Text('Cancellation'),
        subtitle:const Text('Customer can cancel while waiting or during an active ride. Partner can reject requests and cancel an accepted ride when necessary.'),
      )),
    ]),
  );
}

class OnDemandRideTrackingPage extends StatefulWidget {
  final String requestId,rideType;
  const OnDemandRideTrackingPage({super.key,required this.requestId,required this.rideType});
  @override State<OnDemandRideTrackingPage> createState()=>_OnDemandRideTrackingPageState();
}

class _OnDemandRideTrackingPageState extends State<OnDemandRideTrackingPage> {
  Timer? timer;
  @override void initState(){super.initState();timer=Timer.periodic(const Duration(seconds:1),(_){if(mounted)setState((){});});}
  @override void dispose(){timer?.cancel();super.dispose();}

  Future<void> _cancel(BuildContext context,String reason) async {
    final user=FirebaseAuth.instance.currentUser;if(user==null)return;
    final ref=FirebaseFirestore.instance.collection('autoRideRequests').doc(widget.requestId);
    try{
      await FirebaseFirestore.instance.runTransaction((tx)async{
        final latest=await tx.get(ref);final d=latest.data()??<String,dynamic>{};
        if(d['customerUid']!=user.uid)return;
        final st=(d['status']??'').toString().toLowerCase();
        if(st=='searching'||st=='accepted'||st=='arrived'||st=='started'){
          tx.update(ref,{'status':'cancelled','cancelledBy':'customer','cancellationReason':reason,'cancelledAt':FieldValue.serverTimestamp(),'updatedAt':FieldValue.serverTimestamp()});
        }
      });
      if(context.mounted)Navigator.pop(context);
    }catch(e){if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Could not cancel ride: '+e.toString())));}
  }

  @override Widget build(BuildContext context)=>StreamBuilder<DocumentSnapshot<Map<String,dynamic>>>(
    stream:FirebaseFirestore.instance.collection('autoRideRequests').doc(widget.requestId).snapshots(),
    builder:(context,snapshot){
      final d=snapshot.data?.data()??<String,dynamic>{};
      final status=(d['status']??'searching').toString().toLowerCase();
      if(status=='accepted'||status=='arrived'||status=='started'){
        return LiveRideTrackingScreen(
          rideId:widget.requestId,
          isRider:false,
        );
      }
      final created=d['createdAt'];
      DateTime? createdAt=created is Timestamp?created.toDate():null;
      final waited=createdAt==null?0:DateTime.now().difference(createdAt).inSeconds;
      final waitingLong=waited>=60;
      final cancelled=status=='cancelled'||status=='completed';
      return Scaffold(
        appBar:AppBar(title:Text(status=='searching'?'Finding a ride…':'Ride request')),
        body:Column(children:[
          Expanded(child:Center(child:Padding(padding:const EdgeInsets.all(24),child:Column(mainAxisSize:MainAxisSize.min,children:[
            Icon(widget.rideType=='bike'?Icons.two_wheeler:Icons.local_taxi_outlined,size:64),
            const SizedBox(height:12),
            Text(status=='searching'?'Looking for an available '+(widget.rideType=='bike'?'bike':'auto')+' partner…':'Ride '+status,style:const TextStyle(fontSize:19,fontWeight:FontWeight.w900),textAlign:TextAlign.center),
            const SizedBox(height:8),
            Text(waitingLong?'Waiting longer than usual. You can cancel and try again.':'Searching nearby available partners.'),
            if(waited>0)Padding(padding:const EdgeInsets.only(top:8),child:Text('Waiting: '+(waited~/60).toString().padLeft(2,'0')+':'+(waited%60).toString().padLeft(2,'0'),style:const TextStyle(color:Colors.grey))),
            const SizedBox(height:18),
            if(!cancelled)OutlinedButton.icon(onPressed:()=>_cancel(context,waitingLong?'Waiting too long':'Customer cancelled before acceptance'),icon:const Icon(Icons.close),label:Text(waitingLong?'Cancel request':'Cancel ride')),
          ])))),
        ]),
      );
    },
  );
}

class _PopularDestination extends StatelessWidget {
  final String label;
  final IconData icon;
  const _PopularDestination({required this.label,required this.icon});

  @override
  Widget build(BuildContext context){
    final scheme=Theme.of(context).colorScheme;
    return Container(
      width:148,
      margin:const EdgeInsets.only(right:10),
      padding:const EdgeInsets.all(12),
      decoration:BoxDecoration(
        color:scheme.surfaceContainerHighest,
        borderRadius:BorderRadius.circular(18),
        border:Border.all(color:scheme.outlineVariant),
      ),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Icon(icon,color:scheme.onSurface,size:28),
        const Spacer(),
        Text(label,maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(fontWeight:FontWeight.w800,color:scheme.onSurface)),
        const SizedBox(height:3),
        Text('Popular nearby place',style:TextStyle(fontSize:11,color:scheme.onSurfaceVariant)),
      ]),
    );
  }
}

class TravelBookingsSection extends StatelessWidget {
  final String type;
  const TravelBookingsSection({super.key,required this.type});

  Future<void> _reviewReport(BuildContext context,String bookingId) async {
    final review=TextEditingController(); final report=TextEditingController(); int rating=5;
    final action=await showDialog<String>(context:context,builder:(c)=>StatefulBuilder(builder:(c,setState)=>AlertDialog(
      title:Text(type=='ride'?'Ride review / report':'Vehicle review / report'),
      content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
        const Align(alignment:Alignment.centerLeft,child:Text('Review',style:TextStyle(fontWeight:FontWeight.w800))),
        DropdownButtonFormField<int>(initialValue:rating,items:[1,2,3,4,5].map((x)=>DropdownMenuItem(value:x,child:Text(x.toString()+' / 5'))).toList(),onChanged:(v){if(v!=null)setState(()=>rating=v);}),
        TextField(controller:review,maxLines:3,decoration:const InputDecoration(labelText:'Your review (optional)')),
        const SizedBox(height:12),
        const Align(alignment:Alignment.centerLeft,child:Text('Report an issue',style:TextStyle(fontWeight:FontWeight.w800))),
        TextField(controller:report,maxLines:3,decoration:const InputDecoration(labelText:'Report details (optional)')),
      ])),
      actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(c,'save'),child:const Text('Submit'))],
    )));
    if(action!='save') { review.dispose(); report.dispose(); return; }
    final user=FirebaseAuth.instance.currentUser;
    if(user==null) { review.dispose(); report.dispose(); return; }
    if(review.text.trim().isNotEmpty) await FirebaseFirestore.instance.collection('travelReviews').add({'bookingId':bookingId,'bookingType':type,'userUid':user.uid,'rating':rating,'review':review.text.trim(),'createdAt':FieldValue.serverTimestamp()});
    if(report.text.trim().isNotEmpty) await FirebaseFirestore.instance.collection('travelReports').add({'bookingId':bookingId,'bookingType':type,'userUid':user.uid,'report':report.text.trim(),'createdAt':FieldValue.serverTimestamp(),'status':'open'});
    review.dispose(); report.dispose();
    if(context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Review/report submitted.')));
  }

  Future<void> _cancelRideAsCustomer(BuildContext context,String bookingId) async {
    final user=FirebaseAuth.instance.currentUser;
    if(user==null)return;
    try {
      final ref=FirebaseFirestore.instance.collection('rideBookings').doc(bookingId);
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap=await tx.get(ref);
        final d=snap.data()??<String,dynamic>{};
        final status=(d['status']??'').toString().toLowerCase();
        if(d['customerUid']!=user.uid)throw Exception('This booking does not belong to you.');
        if(status=='cancelled'||status=='rejected'||status=='delivered')throw Exception('This ride can no longer be cancelled.');
        tx.update(ref,{'status':'Cancelled','cancelledBy':'customer','cancellationReason':'Customer cancelled the ride','cancelledAt':FieldValue.serverTimestamp(),'updatedAt':FieldValue.serverTimestamp()});
      });
      if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Ride cancelled.')));
    } catch(e) {
      if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));
    }
  }

  @override Widget build(BuildContext context){
    final user=FirebaseAuth.instance.currentUser;
    if(user==null)return const SizedBox.shrink();
    final collection=type=='ride'?'rideBookings':'vehicleBookings';
    return Card(child:ExpansionTile(
      leading:Icon(type=='ride'?Icons.two_wheeler_outlined:Icons.directions_car_outlined),
      title:Text(type=='ride'?'My ride bookings':'My vehicle bookings',style:const TextStyle(fontWeight:FontWeight.w900)),
      children:[
        StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(
          stream:FirebaseFirestore.instance.collection(collection).where('customerUid',isEqualTo:user.uid).snapshots(),
          builder:(context,snapshot){
            if(snapshot.hasError)return const Padding(padding:EdgeInsets.all(16),child:Text('Bookings unavailable.'));
            if(!snapshot.hasData)return const Padding(padding:EdgeInsets.all(16),child:CircularProgressIndicator());
            if(snapshot.data!.docs.isEmpty)return const Padding(padding:EdgeInsets.all(16),child:Text('No bookings yet.'));
            return Column(children:snapshot.data!.docs.take(20).map((doc){
              final d=doc.data();
              final name=(d['partnerName']??d['ownerName']??'Booking').toString();
              final status=(d['status']??'').toString();
              return ListTile(
                title:Text(name,style:const TextStyle(fontWeight:FontWeight.w800)),
                subtitle:Text(status+(d['price']!=null?' • ₹'+d['price'].toString():'')+(d['destination']!=null?' • '+d['destination'].toString():'')),
                trailing:Wrap(spacing:4,children:[
                  if(status.toLowerCase()!='rejected'&&status.toLowerCase()!='cancelled'&&status.toLowerCase()!='delivered')
                    OutlinedButton(
                      onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>LiveTrackingScreen(
                        collection:collection,
                        docId:doc.id,
                        title:type=='ride'?'Live ride tracking':'Live vehicle tracking',
                        mode:type=='ride'?'ride':'vehicle',
                        broadcastPrefix:'customer',
                        allowCancel:type=='ride',
                      ))),
                      child:const Text('Track'),
                    ),
                  if(type=='ride'&&status.toLowerCase()!='rejected'&&status.toLowerCase()!='cancelled'&&status.toLowerCase()!='delivered')
                    TextButton(onPressed:()=>_cancelRideAsCustomer(context,doc.id),child:const Text('Cancel')),
                  OutlinedButton(onPressed:()=>_reviewReport(context,doc.id),child:const Text('Review / Report')),
                ]),
              );
            }).toList());
          },
        ),
      ],
    ));
  }
}

class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Policy')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: const [
          Text('ALLways Privacy Policy', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
          SizedBox(height: 12),
          Text('ALLways uses account information to authenticate customers, process orders and provide delivery updates. Delivery addresses and order details are used to fulfill orders. Wishlist and saved-address data are stored under your customer account.'),
          SizedBox(height: 14),
          Text('Information sharing', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          Text('ALLways shares order information with people who need it to fulfill an order, such as authorized delivery partners and administrators. ALLways uses information only for the services and features you use.'),
          SizedBox(height: 14),
          Text('Location sharing', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          Text('When you start an active delivery, ride or vehicle-tracking session, ALLways can use your device location to show your live position to the other authorized participant(s) and to ALLways administrators for fulfillment and safety. Location sharing is limited to the active session and is stopped when the session ends. Background location may be used while an active tracking session is running so the map can continue updating when the screen is off.'),
          SizedBox(height: 14),
          Text('Notifications', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          Text('ALLways uses Firebase Cloud Messaging for order, delivery, travel and service notifications. You can enable or disable notification categories in the Notifications settings.'),
          SizedBox(height: 14),
          Text('Maps', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          Text('ALLways uses OpenStreetMap-based map data for live tracking. © OpenStreetMap contributors.'),
          SizedBox(height: 14),
          Text('Your choices', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          Text('You can manage saved addresses, wishlist items, notification settings and active location sharing in the app, and you can request account-related changes through ALLways support.'),
        ],
      ),
    );
  }
}

class SavedAddressesPage extends StatefulWidget {
  final String userId;
  final List<Map<String, dynamic>> addresses;
  final Future<void> Function() onReload;
  final Future<void> Function(String) onDelete;
  const SavedAddressesPage({super.key, required this.userId, required this.addresses, required this.onReload, required this.onDelete});

  @override
  State<SavedAddressesPage> createState() => _SavedAddressesPageState();
}

class _SavedAddressesPageState extends State<SavedAddressesPage> {
  bool saving=false;

  Future<void> _editAddress(Map<String,dynamic> item) async {
    final name=TextEditingController(text:(item['name']??'').toString());
    final phone=TextEditingController(text:(item['phone']??'').toString());
    final address=TextEditingController(text:(item['address']??'').toString());
    final formKey=GlobalKey<FormState>();
    final id=(item['id']??'').toString();
    if(widget.userId.isEmpty || id.isEmpty){
      name.dispose();phone.dispose();address.dispose();
      return;
    }
    try{
      final save=await showDialog<bool>(
        context:context,
        builder:(dialogContext)=>AlertDialog(
          title:const Text('Edit address'),
          content:Form(
            key:formKey,
            child:SingleChildScrollView(
              child:Column(
                mainAxisSize:MainAxisSize.min,
                children:[
                  TextFormField(controller:name,decoration:const InputDecoration(labelText:'Name'),validator:(v)=>v==null||v.trim().isEmpty?'Enter a name':null),
                  const SizedBox(height:10),
                  TextFormField(controller:phone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'Phone'),validator:(v)=>v==null||!RegExp(r'^\d{10}$').hasMatch(v.replaceAll(RegExp(r'\D'),'').trim())?'Enter a valid 10-digit phone':null),
                  const SizedBox(height:10),
                  TextFormField(controller:address,maxLines:3,decoration:const InputDecoration(labelText:'Address'),validator:(v)=>v==null||v.trim().isEmpty?'Enter an address':null),
                ],
              ),
            ),
          ),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(dialogContext,false),child:const Text('Cancel')),
            FilledButton(onPressed:(){if(formKey.currentState?.validate()??false)Navigator.pop(dialogContext,true);},child:const Text('Save changes')),
          ],
        ),
      );
      if(save!=true)return;
      setState(()=>saving=true);
      final cleanPhone=phone.text.replaceAll(RegExp(r'\D'),'').trim();
      await FirebaseFirestore.instance.collection('customers').doc(widget.userId).collection('addresses').doc(id).update({
        'name':name.text.trim(),
        'phone':cleanPhone,
        'address':address.text.trim(),
      });
      await widget.onReload();
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Address updated.')));
    }catch(e){
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Could not update address: '+e.toString())));
    }finally{
      name.dispose();phone.dispose();address.dispose();
      if(mounted)setState(()=>saving=false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar:AppBar(title:const Text('Saved addresses')),
      body:RefreshIndicator(
        onRefresh:widget.onReload,
        child:ListView(
          padding:const EdgeInsets.all(16),
          children:[
            if(widget.addresses.isEmpty)
              const InfoCard(title:'No saved addresses',detail:'An address is saved after a successful order.')
            else
              ...widget.addresses.map((x)=>Card(
                child:ListTile(
                  title:Text((x['name']??'').toString()),
                  subtitle:Text((x['address']??'').toString()),
                  trailing:Row(
                    mainAxisSize:MainAxisSize.min,
                    children:[
                      IconButton(tooltip:'Edit',onPressed:saving?null:()=>_editAddress(x),icon:const Icon(Icons.edit)),
                      IconButton(tooltip:'Delete',onPressed:saving?null:()=>widget.onDelete(x['id'].toString()),icon:const Icon(Icons.delete_outline)),
                    ],
                  ),
                ),
              )),
          ],
        ),
      ),
    );
  }
}

class WishlistPage extends StatefulWidget {
  final void Function(Product)? onAdd;
  final VoidCallback? onBuyAll;
  const WishlistPage({super.key, this.onAdd, this.onBuyAll});
  @override State<WishlistPage> createState() => _WishlistPageState();
}

class _WishlistPageState extends State<WishlistPage> {
  bool loading = true;
  String? error;
  List<Product> items = [];

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) {
      if (mounted) setState(() => loading = false);
      return;
    }
    try {
      final snap = await FirebaseFirestore.instance.collection('customers').doc(u.uid).collection('wishlist').orderBy('addedAt', descending: true).get();
      final list = snap.docs.map((d) => Product.fromJson(d.data())).toList();
      if (mounted) setState(() { items = list; loading = false; error = null; });
    } catch (_) {
      if (mounted) setState(() { loading = false; error = 'Could not load wishlist.'; });
    }
  }

  Future<void> remove(Product product) async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;
    try {
      await FirebaseFirestore.instance.collection('customers').doc(u.uid).collection('wishlist').doc(product.id).delete();
      if (mounted) setState(() => items.removeWhere((x) => x.id == product.id));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not remove item.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (error != null) {
      body = Center(child: Text(error!));
    } else if (items.isEmpty) {
      body = ListView(
        children: const [
          SizedBox(height: 80),
          Icon(Icons.favorite_border, size: 72),
          SizedBox(height: 12),
          Center(child: Text('Your wishlist is empty', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
        ],
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Row(children:[
              Expanded(child:OutlinedButton.icon(
                onPressed: widget.onAdd==null?null:(){
                  for(final p in List<Product>.from(items)) widget.onAdd!(p);
                  if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Added '+items.length.toString()+' wishlist items to cart.')));
                },
                icon:const Icon(Icons.add_shopping_cart),
                label:const Text('Add all to cart'),
              )),
              const SizedBox(width:8),
              Expanded(child:FilledButton.icon(
                onPressed: widget.onBuyAll==null?null:(){
                  if(widget.onAdd!=null){
                    for(final p in List<Product>.from(items)) widget.onAdd!(p);
                  }
                  widget.onBuyAll!();
                },
                icon:const Icon(Icons.shopping_bag_outlined),
                label:const Text('Buy all'),
              )),
            ]),
          ),
          const SizedBox(height:10),
          ...items.map(

          (p) => Card(
            child: ListTile(
              leading: CircleAvatar(child: Text(p.icon)),
              title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text('₹' + p.price.toString() + ' • ' + p.category),
              trailing: IconButton(onPressed: () => remove(p), icon: const Icon(Icons.favorite)),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ProductScreen(product: p, onAdd: () { if (widget.onAdd != null) { widget.onAdd!(p); } else { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Open Wishlist from Shop or Profile to add items to the cart.'))); } }, liked: true, onWishlist: () => remove(p))),
              ),
            ),
          ),
        ),
      );
    }
    return Scaffold(appBar: AppBar(title: const Text('Wishlist')), body: RefreshIndicator(onRefresh: load, child: body));
  }
}

class AuthScreen extends StatefulWidget{const AuthScreen({super.key});State<AuthScreen> createState()=>_AuthState();}
class _AuthState extends State<AuthScreen>{
  final email=TextEditingController(),pass=TextEditingController(),name=TextEditingController();bool signup=false,busy=false,hide=true;
  @override void dispose(){email.dispose();pass.dispose();name.dispose();super.dispose();}
  String err(Object e){if(e is FirebaseAuthException){if(e.code=='invalid-credential'||e.code=='wrong-password')return'Email or password is incorrect. Use Forgot password if this is an existing account.';if(e.code=='user-not-found')return'No account exists with this email.';if(e.code=='email-already-in-use')return'An account already exists with this email.';if(e.code=='weak-password')return'Use a stronger password.';if(e.code=='invalid-email')return'Enter a valid email address.';return e.message??'Authentication failed.';}return'Something went wrong.';}
  Future<void> googleSignIn() async {
    setState(() => busy = true);
    try {
      final signIn = GoogleSignIn.instance;
      // Initialize Google Sign-In only when the user actually chooses Google.
      // Keeping this out of app startup prevents an auth-plugin initialization
      // failure from preventing the entire ALLways app from opening.
      await signIn.initialize(
        serverClientId: '869987297351-bonithsodhkkhb8a994d6hbiau8a3ltv.apps.googleusercontent.com',
      );
      // Do not sign out immediately before authentication. With Android's
      // Credential Manager flow this can force an unnecessary account reauth
      // and surface as [16] Account reauth failed. authenticate() can show
      // the account chooser itself when needed.
      final GoogleSignInAccount account = await signIn.authenticate();
      final GoogleSignInAuthentication auth = account.authentication;
      final idToken = auth.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw Exception('Google did not return an ID token.');
      }
      final credential = GoogleAuthProvider.credential(idToken: idToken);
      await FirebaseAuth.instance.signInWithCredential(credential);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e is FirebaseAuthException ? err(e) : 'Google sign-in failed: '+e.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> submit()async{setState(()=>busy=true);try{if(signup){final x=await FirebaseAuth.instance.createUserWithEmailAndPassword(email:email.text.trim(),password:pass.text);if(name.text.trim().isNotEmpty)await x.user?.updateDisplayName(name.text.trim());}else{await FirebaseAuth.instance.signInWithEmailAndPassword(email:email.text.trim().toLowerCase(),password:pass.text.trim());}if(mounted)Navigator.pop(context);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(err(e))));}finally{if(mounted)setState(()=>busy=false);}}
  Future<void> reset()async{if(email.text.trim().isEmpty){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Enter your email first.')));return;}try{await FirebaseAuth.instance.sendPasswordResetEmail(email:email.text.trim());if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Password reset email sent.')));}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(err(e))));}}
  Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:Text(signup?'Create ALLways account':'Sign in')),body:ListView(padding:const EdgeInsets.all(20),children:[
    const Text('ALLways',style:TextStyle(fontSize:34,fontWeight:FontWeight.w900)),const Text('Closer to You, Always',style:TextStyle(color:Colors.grey)),const SizedBox(height:25),
    if(signup)TextField(controller:name,decoration:const InputDecoration(labelText:'Your name')),if(signup)const SizedBox(height:10),
    TextField(controller:email,keyboardType:TextInputType.emailAddress,decoration:const InputDecoration(labelText:'Email')),const SizedBox(height:10),
    TextField(controller:pass,obscureText:hide,decoration:InputDecoration(labelText:'Password',suffixIcon:IconButton(onPressed:()=>setState(()=>hide=!hide),icon:Icon(hide?Icons.visibility:Icons.visibility_off)))),const SizedBox(height:16),
    FilledButton(onPressed:busy?null:submit,child:Text(busy?'Please wait…':signup?'Create account':'Sign in')),
    if(!signup) ...[
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: busy ? null : googleSignIn,
        icon: const Icon(Icons.account_circle_outlined),
        label: const Text('Continue with Google'),
      ),
      const SizedBox(height: 4),
    ],
    if(!signup)TextButton(onPressed:busy?null:reset,child:const Text('Forgot password?')),
    TextButton(onPressed:busy?null:()=>setState(()=>signup=!signup),child:Text(signup?'Already have an account? Sign in':'Create a new account'))
  ]));
}

class InfoCard extends StatelessWidget{final String title,detail;const InfoCard({super.key,required this.title,required this.detail});Widget build(BuildContext c)=>Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:const TextStyle(fontWeight:FontWeight.w800)),const SizedBox(height:6),Text(detail,style:const TextStyle(color:Colors.grey))])));}