import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'role_workspace_screen.dart';
import 'allways_design.dart';

class RoleDashboardScreen extends StatefulWidget {
  final String role;
  final User user;
  final Widget child;
  final VoidCallback onSignOut;
  const RoleDashboardScreen({super.key,required this.role,required this.user,required this.child,required this.onSignOut});
  @override State<RoleDashboardScreen> createState()=>_RoleDashboardScreenState();
}

class _RoleDashboardScreenState extends State<RoleDashboardScreen>{
  int tab=0;
  Map<String,dynamic> profile={};
  bool loading=true;
  bool busyStatus=false;

  Color get accent=>switch(widget.role){
    'admin'=>const Color(0xFFC2185B),'seller'=>const Color(0xFF087F43),'delivery_partner'=>const Color(0xFF1565C0),'carrier'=>const Color(0xFF5B1ACF),_=>Colors.black
  };
  bool get admin=>widget.role=='admin';
  bool get seller=>widget.role=='seller';
  bool get delivery=>widget.role=='delivery_partner';
  bool get carrier=>widget.role=='carrier';
  String get title=>switch(widget.role){
    'admin'=>'ALLways Admin','seller'=>'ALLways Seller','delivery_partner'=>'ALLways Delivery Partner','carrier'=>'ALLways Rider',_=>'ALLways'
  };
  IconData get icon=>switch(widget.role){
    'admin'=>Icons.workspace_premium,'seller'=>Icons.storefront,'delivery_partner'=>Icons.local_shipping,'carrier'=>Icons.two_wheeler,_=>Icons.dashboard
  };
  String get status{
    if(admin)return 'Super Admin';
    if(seller)return 'Verified Seller';
    return (profile['status']??profile['dutyStatus']??'offline').toString().toLowerCase()=='online'?'Online':'Offline';
  }
  bool get online=>status=='Online';

  @override void initState(){super.initState();_load();}
  Future<void> _load()async{
    try{
      final col=seller?'sellers':carrier?'ridePartners':'customers';
      final snap=await FirebaseFirestore.instance.collection(col).doc(widget.user.uid).get();
      if(mounted)setState(()=>profile=snap.data()??{});
    }catch(_){}
    if(mounted)setState(()=>loading=false);
  }

  List<_Action> get actions=>switch(widget.role){
    'admin'=>const[
      _Action('Manage Orders',Icons.receipt_long,'Operations'),_Action('Manage Delivery Partners',Icons.local_shipping,'Operations'),_Action('Manage Carriers',Icons.two_wheeler,'Operations'),_Action('Manage Sellers',Icons.storefront,'Operations'),
      _Action('Manage Banners',Icons.view_carousel,'Content'),_Action('Homepage & Content',Icons.home_work,'Content'),_Action('Send Notifications',Icons.campaign,'Content'),
      _Action('Users & Roles',Icons.manage_accounts,'People'),_Action('Reports & Analytics',Icons.analytics,'Analytics'),_Action('App Settings',Icons.settings,'Settings'),
    ],
    'seller'=>const[
      _Action('Products',Icons.inventory_2,'Store'),_Action('Inventory',Icons.fact_check,'Store'),_Action('Shop Profile',Icons.storefront,'Store'),_Action('Orders',Icons.receipt_long,'Orders'),
      _Action('Offers',Icons.local_offer,'Growth'),_Action('Sales Analytics',Icons.bar_chart,'Growth'),_Action('Payouts',Icons.account_balance_wallet,'Finance'),_Action('Help & Support',Icons.support_agent,'Account'),
    ],
    'delivery_partner'=>const[
      _Action('Delivery Requests',Icons.local_shipping,'Work'),_Action('My Deliveries',Icons.assignment_turned_in,'Work'),_Action('Earnings',Icons.currency_rupee,'Finance'),_Action('Incentives',Icons.card_giftcard,'Finance'),
      _Action('Performance',Icons.bar_chart,'Performance'),_Action('Documents',Icons.description,'Account'),_Action('Safety & SOS',Icons.shield,'Safety'),_Action('Help & Support',Icons.support_agent,'Account'),
    ],
    _=>const[
      _Action('Ride Requests',Icons.two_wheeler,'Rides'),_Action('My Rides',Icons.route,'Rides'),_Action('Ride History',Icons.history,'Rides'),_Action('Earnings',Icons.currency_rupee,'Finance'),
      _Action('Ratings',Icons.star,'Performance'),_Action('Vehicle & Documents',Icons.description,'Account'),_Action('Safety & SOS',Icons.shield,'Safety'),_Action('Help & Support',Icons.support_agent,'Account'),
    ],
  };

  Future<void> _setOnline(bool value)async{
    if(!carrier&&!delivery)return;
    setState(()=>busyStatus=true);
    try{
      final col=carrier?'ridePartners':'customers';
      final data=carrier?{'status':value?'online':'offline','availableForRides':value,'statusUpdatedAt':FieldValue.serverTimestamp()}:{'status':value?'online':'offline','availableForDeliveries':value,'dutyStatus':value?'online':'offline','statusUpdatedAt':FieldValue.serverTimestamp()};
      await FirebaseFirestore.instance.collection(col).doc(widget.user.uid).set(data,SetOptions(merge:true));
      if(mounted)setState(()=>profile={...profile,...data});
    }catch(e){
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Could not update status: '+e.toString())));
    }finally{if(mounted)setState(()=>busyStatus=false);}
  }

  void open(String feature)=>Navigator.push(context,MaterialPageRoute(builder:(_)=>RoleFeatureScreen(role:widget.role,feature:feature,user:widget.user,accent:accent))).then((_)=>_load());

  @override Widget build(BuildContext context){
    // Carrier uses its own dedicated ride-partner application shell.
    if(carrier)return widget.child;
    return Scaffold(
      backgroundColor:Theme.of(context).colorScheme.surface,
      body:SafeArea(child:IndexedStack(index:tab,children:[_home(),_categoryPage(admin?'Operations':delivery?'Deliveries':'Orders'),_categoryPage('Analytics'),_categoryPage('Account')])),
      bottomNavigationBar:AllwaysBottomNav(
        selectedIndex:tab,
        onSelected:(v)=>setState(()=>tab=v),
        items:[
          (icon:Icons.home_outlined,activeIcon:Icons.home,label:'Home'),
          (icon:admin?Icons.tune:delivery?Icons.local_shipping:Icons.receipt_long,activeIcon:admin?Icons.tune:delivery?Icons.local_shipping:Icons.receipt_long,label:admin?'Operations':delivery?'Deliveries':'Orders'),
          (icon:admin?Icons.analytics:Icons.account_balance_wallet,activeIcon:admin?Icons.analytics:Icons.account_balance_wallet,label:admin?'Analytics':'Earnings'),
          (icon:Icons.person_outline,activeIcon:Icons.person,label:'Account'),
        ],
      ),
    );
  }

  Widget _home()=>RefreshIndicator(onRefresh:_load,child:ListView(padding:const EdgeInsets.fromLTRB(16,10,16,24),children:[
    Row(children:[Icon(icon,color:accent,size:30),const SizedBox(width:9),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:const TextStyle(fontSize:23,fontWeight:FontWeight.w900)),Text(widget.user.email??'',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:11,color:Colors.grey))]))]),
    const SizedBox(height:14),
    _profileCard(),
    const SizedBox(height:16),
    _liveStats(),
    const SizedBox(height:18),
    Text(admin?'Platform control center':seller?'Seller workspace':delivery?'Delivery workspace':'Rider workspace',style:const TextStyle(fontSize:21,fontWeight:FontWeight.w900)),
    const SizedBox(height:10),
    ..._groupedActions(),
    const SizedBox(height:18),
    _recent(),
  ]));

  Widget _profileCard()=>Card(elevation:0,color:accent.withOpacity(.07),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(22)),child:Padding(padding:const EdgeInsets.all(16),child:Row(children:[
    CircleAvatar(radius:29,backgroundColor:accent.withOpacity(.13),child:Text(_name.substring(0,1).toUpperCase(),style:TextStyle(fontSize:23,fontWeight:FontWeight.w900,color:accent))),
    const SizedBox(width:13),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(_name,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:18,fontWeight:FontWeight.w900)),Text(_roleLine,style:TextStyle(color:accent,fontWeight:FontWeight.w700,fontSize:12))])),
    if(carrier||delivery)Switch(value:online,onChanged:busyStatus?null:_setOnline),
    if(admin||seller)IconButton(onPressed:()=>open(seller?'Shop Profile':'Users & Roles'),icon:const Icon(Icons.chevron_right)),
  ])));

  String get _name{final n=(profile['businessName']??profile['shopName']??profile['name']??profile['displayName']??'').toString().trim();return n.isEmpty?(widget.user.displayName??'ALLways Account'):n;}
  String get _roleLine=>admin?'Full platform access':seller?'Store and catalogue management':delivery?'Deliveries, earnings and safety':online?'Online • accepting nearby rides':'Offline • tap the switch to go online';

  Widget _liveStats()=>StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(
    stream:FirebaseFirestore.instance.collection('orders').snapshots(),
    builder:(context,s){
      final docs=s.data?.docs??const <QueryDocumentSnapshot<Map<String,dynamic>>>[];
      final scoped=docs.where((d){
        final o=d.data();
        if(seller)return (o['sellerId']??o['sellerUid']??'').toString()==widget.user.uid;
        if(carrier||delivery)return (o['carrierUid']??'').toString()==widget.user.uid;
        return true;
      }).toList();
      final pending=scoped.where((d)=>(d.data()['status']??'').toString().toLowerCase().contains('pending')||(d.data()['status']??'').toString().toLowerCase()=='new order').length;
      final done=scoped.where((d){final x=(d.data()['status']??'').toString().toLowerCase();return x=='delivered'||x=='completed';}).length;
      num value=0;for(final d in scoped)value+=(d.data()['total'] is num?d.data()['total']:num.tryParse((d.data()['total']??0).toString())??0);
      return Row(children:[
        _stat(pending.toString(),admin?'Pending orders':seller?'Pending orders':carrier?'Open rides':'Open deliveries',Icons.pending_actions),
        const SizedBox(width:8),_stat(done.toString(),'Completed',Icons.check_circle_outline),
        const SizedBox(width:8),_stat('₹'+value.toStringAsFixed(0),'Order value',Icons.currency_rupee),
      ]);
    },
  );
  Widget _stat(String v,String l,IconData i)=>Expanded(child:Card(elevation:0,child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Icon(i,color:accent,size:20),const SizedBox(height:7),Text(v,style:const TextStyle(fontSize:18,fontWeight:FontWeight.w900)),Text(l,maxLines:2,style:const TextStyle(fontSize:10,color:Colors.grey))]))));

  List<Widget> _groupedActions(){
    final groups=<String,List<_Action>>{};
    for(final a in actions){groups.putIfAbsent(a.group,()=>[]).add(a);}
    final out=<Widget>[];
    groups.forEach((group,items){
      out.add(Padding(padding:const EdgeInsets.only(top:4,bottom:8),child:Text(group.toUpperCase(),style:TextStyle(fontSize:11,fontWeight:FontWeight.w900,color:accent))));
      out.add(GridView.builder(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),itemCount:items.length,gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:3,mainAxisSpacing:9,crossAxisSpacing:9,childAspectRatio:.96),itemBuilder:(context,i){
        final a=items[i];return InkWell(onTap:()=>open(a.title),borderRadius:BorderRadius.circular(16),child:Container(padding:const EdgeInsets.all(8),decoration:BoxDecoration(color:Colors.white,borderRadius:BorderRadius.circular(16),border:Border.all(color:accent.withOpacity(.08))),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[Icon(a.icon,color:accent,size:26),const SizedBox(height:7),Text(a.title,textAlign:TextAlign.center,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:11.5,fontWeight:FontWeight.w700))])));
      }));
      out.add(const SizedBox(height:12));
    });
    return out;
  }

  Widget _categoryPage(String category){
    final items=actions.where((x){
      if(category=='Operations')return x.group=='Operations'||x.group=='Work'||x.group=='Rides'||x.group=='Store'||x.group=='Orders';
      if(category=='Analytics')return x.group=='Analytics'||x.group=='Growth'||x.group=='Performance'||x.group=='Finance';
      return x.group=='Account'||x.group=='Safety'||x.group=='Content'||x.group=='People'||x.group=='Settings'||x.group=='Account';
    }).toList();
    return ListView(padding:const EdgeInsets.fromLTRB(16,22,16,28),children:[
      Text(category,style:const TextStyle(fontSize:28,fontWeight:FontWeight.w900)),const SizedBox(height:5),Text('Everything is organized by task so every option has a clear destination.',style:const TextStyle(color:Colors.grey)),const SizedBox(height:16),
      ...items.map((a)=>Card(elevation:0,child:ListTile(contentPadding:const EdgeInsets.symmetric(horizontal:16,vertical:5),leading:CircleAvatar(backgroundColor:accent.withOpacity(.1),child:Icon(a.icon,color:accent)),title:Text(a.title,style:const TextStyle(fontWeight:FontWeight.w800)),subtitle:Text(a.group+' • Open dedicated workspace'),trailing:Icon(Icons.chevron_right,color:accent),onTap:()=>open(a.title)))),
    ]);
  }

  Widget _recent()=>StreamBuilder<QuerySnapshot<Map<String,dynamic>>>(stream:FirebaseFirestore.instance.collection('orders').orderBy('createdAt',descending:true).limit(5).snapshots(),builder:(context,s){if(!s.hasData)return const SizedBox.shrink();return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Row(children:[const Text('Recent activity',style:TextStyle(fontSize:19,fontWeight:FontWeight.w900)),const Spacer(),TextButton(onPressed:()=>open(admin?'Manage Orders':seller?'Orders':carrier?'My Rides':'My Deliveries'),child:Text('View all',style:TextStyle(color:accent)))]),
    ...s.data!.docs.map((d){final o=d.data();return Card(elevation:0,child:ListTile(onTap:()=>open(admin?'Manage Orders':seller?'Orders':carrier?'My Rides':'My Deliveries'),leading:CircleAvatar(backgroundColor:accent.withOpacity(.1),child:Icon(carrier?Icons.two_wheeler:delivery?Icons.local_shipping:Icons.receipt_long,color:accent)),title:Text('#'+(o['id']??d.id).toString(),style:const TextStyle(fontWeight:FontWeight.w800)),subtitle:Text((o['name']??o['customerName']??'Customer').toString()),trailing:Text('₹'+(o['total']??0).toString(),style:const TextStyle(fontWeight:FontWeight.w800))));}),
  ]);});
}

class _Action{final String title;final IconData icon;final String group;const _Action(this.title,this.icon,this.group);}
