import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;

class AdminCmsScreen extends StatefulWidget {
  final String section;
  const AdminCmsScreen({super.key, required this.section});
  @override State<AdminCmsScreen> createState() => _AdminCmsScreenState();
}

class _AdminCmsScreenState extends State<AdminCmsScreen> {
  static const cloudName = 'busdtvia';
  static const uploadPreset = 'allways_preset';
  final bannerUrl = TextEditingController();
  final heroTitle = TextEditingController();
  final heroSubtitle = TextEditingController();
  final deliveryText = TextEditingController();
  List<String> banners = [];
  int rotationSeconds = 4;
  bool showCategories = true, showOffers = true, showPopular = true, showLocalSellers = true, showTravel = true;
  bool codEnabled = true, loading = true, saving = false;

  @override void initState() { super.initState(); _load(); }
  @override void dispose() { bannerUrl.dispose(); heroTitle.dispose(); heroSubtitle.dispose(); deliveryText.dispose(); super.dispose(); }

  Future<void> _load() async {
    try {
      final b = await FirebaseFirestore.instance.collection('settings').doc('banners').get();
      final h = await FirebaseFirestore.instance.collection('settings').doc('homepage').get();
      final s = await FirebaseFirestore.instance.collection('settings').doc('app').get();
      final bd = b.data() ?? {}, hd = h.data() ?? {}, sd = s.data() ?? {};
      final raw = bd['imageUrls'];
      banners = raw is List ? raw.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).take(7).toList() : <String>[];
      rotationSeconds = ((bd['rotationSeconds'] is num ? (bd['rotationSeconds'] as num).toInt() : int.tryParse((bd['rotationSeconds'] ?? 4).toString()) ?? 4)).clamp(2, 20).toInt();
      heroTitle.text = (hd['heroTitle'] ?? 'Closer to You, Always').toString();
      heroSubtitle.text = (hd['heroSubtitle'] ?? 'Everything you need, delivered locally.').toString();
      deliveryText.text = (hd['deliveryText'] ?? 'Fast local delivery').toString();
      showCategories = hd['showCategories'] != false;
      showOffers = hd['showOffers'] != false;
      showPopular = hd['showPopular'] != false;
      showLocalSellers = hd['showLocalSellers'] != false;
      showTravel = hd['showTravel'] != false;
      codEnabled = sd['codEnabled'] != false;
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  Future<void> _save(String label) async {
    setState(() => saving = true);
    try {
      await FirebaseFirestore.instance.collection('settings').doc('banners').set({
        'imageUrls': banners.take(7).toList(), 'rotationSeconds': rotationSeconds, 'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await FirebaseFirestore.instance.collection('settings').doc('homepage').set({
        'heroTitle': heroTitle.text.trim(), 'heroSubtitle': heroSubtitle.text.trim(), 'deliveryText': deliveryText.text.trim(),
        'showCategories': showCategories, 'showOffers': showOffers, 'showPopular': showPopular,
        'showLocalSellers': showLocalSellers, 'showTravel': showTravel, 'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await FirebaseFirestore.instance.collection('settings').doc('app').set({'codEnabled': codEnabled, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(label + ' saved.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: ' + e.toString())));
    } finally { if (mounted) setState(() => saving = false); }
  }

  Future<void> _addUrl() async {
    final url = bannerUrl.text.trim();
    if (url.isEmpty || banners.length >= 7) return;
    if (!url.startsWith('http')) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a valid image URL.'))); return; }
    setState(() { banners.add(url); bannerUrl.clear(); });
  }

  Future<void> _uploadBanner() async {
    if (banners.length >= 7) return;
    final image = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 65, maxWidth: 1200);
    if (image == null) return;
    try {
      final request = http.MultipartRequest('POST', Uri.parse('https://api.cloudinary.com/v1_1/$cloudName/image/upload'));
      request.fields['upload_preset'] = uploadPreset;
      request.fields['folder'] = 'admin/banners';
      request.files.add(await http.MultipartFile.fromPath('file', image.path));
      final response = await request.send();
      final data = jsonDecode(await response.stream.bytesToString());
      final url = (data['secure_url'] ?? '').toString();
      if (url.isEmpty) throw Exception('Cloudinary did not return secure_url.');
      if (mounted) setState(() => banners.add(url));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Banner upload failed: ' + e.toString())));
    }
  }

  Widget _card(String title, String subtitle, Widget child) => Card(
    margin: const EdgeInsets.only(bottom: 14), elevation: 0,
    child: Padding(padding: const EdgeInsets.fromLTRB(16,16,16,10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
      const SizedBox(height: 4), Text(subtitle, style: const TextStyle(color: Colors.grey)),
      const SizedBox(height: 12), child,
    ])),
  );

  Widget _banners() => _card('Banner Manager','Maximum 7 banners. Changes are stored in Firestore and do not require a new APK.',Column(children:[
    ...List.generate(banners.length,(i)=>ListTile(
      contentPadding: EdgeInsets.zero,
      leading: ClipRRect(borderRadius: BorderRadius.circular(10),child:Image.network(banners[i],width:70,height:45,fit:BoxFit.cover,errorBuilder:(_,__,___)=>const SizedBox(width:70,height:45,child:Icon(Icons.broken_image)))),
      title: Text('Banner '+(i+1).toString(),style:const TextStyle(fontWeight:FontWeight.w800)),
      subtitle: Text(banners[i],maxLines:1,overflow:TextOverflow.ellipsis),
      trailing: IconButton(icon:const Icon(Icons.delete_outline),onPressed:()=>setState(()=>banners.removeAt(i))),
    )),
    if(banners.isEmpty) const Align(alignment:Alignment.centerLeft,child:Text('No banners configured yet.')),
    const SizedBox(height:6),
    Row(children:[Expanded(child:TextField(controller:bannerUrl,decoration:const InputDecoration(labelText:'Cloudinary image URL',prefixIcon:Icon(Icons.link)))),IconButton(onPressed:_addUrl,icon:const Icon(Icons.add_circle))]),
    const SizedBox(height:8),
    Row(children:[
      Expanded(child:OutlinedButton.icon(onPressed:_uploadBanner,icon:const Icon(Icons.upload),label:const Text('Upload banner'))),
      const SizedBox(width:8),
      Expanded(child:DropdownButtonFormField<int>(initialValue:[2,3,4,5,6,8,10].contains(rotationSeconds)?rotationSeconds:4,decoration:const InputDecoration(labelText:'Rotation'),items:[2,3,4,5,6,8,10].map((x)=>DropdownMenuItem(value:x,child:Text(x.toString()+' sec'))).toList(),onChanged:(v)=>setState(()=>rotationSeconds=v??4))),
    ]),
  ]));

  Widget _homepage() => _card('Homepage content','Control customer-facing sections without shipping another APK.',Column(children:[
    TextField(controller:heroTitle,decoration:const InputDecoration(labelText:'Hero title')),
    const SizedBox(height:10),TextField(controller:heroSubtitle,maxLines:2,decoration:const InputDecoration(labelText:'Hero subtitle')),
    const SizedBox(height:10),TextField(controller:deliveryText,decoration:const InputDecoration(labelText:'Delivery message')),
    const Divider(height:26),
    SwitchListTile(title:const Text('Categories'),value:showCategories,onChanged:(v)=>setState(()=>showCategories=v)),
    SwitchListTile(title:const Text('Top offers'),value:showOffers,onChanged:(v)=>setState(()=>showOffers=v)),
    SwitchListTile(title:const Text('Popular products'),value:showPopular,onChanged:(v)=>setState(()=>showPopular=v)),
    SwitchListTile(title:const Text('Local sellers shortcut'),value:showLocalSellers,onChanged:(v)=>setState(()=>showLocalSellers=v)),
    SwitchListTile(title:const Text('Travel shortcut'),value:showTravel,onChanged:(v)=>setState(()=>showTravel=v)),
  ]));

  @override Widget build(BuildContext context){
    if(loading)return const Scaffold(body:Center(child:CircularProgressIndicator()));
    final section=widget.section;
    return Scaffold(
      appBar:AppBar(title:Text(section)),
      body:ListView(padding:const EdgeInsets.fromLTRB(16,14,16,28),children:[
        if(section=='Manage Banners')_banners(),
        if(section=='Homepage & Content')_homepage(),
        if(section=='App Settings')...[_banners(),_homepage(),_card('Order settings','Platform-level defaults.',SwitchListTile(title:const Text('Cash on Delivery'),subtitle:const Text('Keep COD enabled for ALLways managed shopping.'),value:codEnabled,onChanged:(v)=>setState(()=>codEnabled=v)))],
        FilledButton.icon(onPressed:saving?null:()=>_save(section),icon:const Icon(Icons.save_outlined),label:Text(saving?'Saving…':'Save changes')),
      ]),
    );
  }
}
