"use strict";

const crypto=require("crypto");
const {getFirestore,FieldValue}=require("firebase-admin/firestore");
const {onCall,HttpsError}=require("firebase-functions/v2/https");
const db=getFirestore();

function numberOr(value,fallback){const n=Number(value);return Number.isFinite(n)?n:fallback;}
function safeText(value,max,label,required=false){
 const v=String(value??"").trim();
 if(required&&!v)throw new HttpsError("invalid-argument",label+" is required.");
 if(v.length>max)throw new HttpsError("invalid-argument",label+" is too long.");
 return v;
}
function distanceKm(a,b,c,d){
 const rad=Math.PI/180,p1=a*rad,p2=c*rad,dl=(c-a)*rad,dg=(d-b)*rad;
 const z=Math.sin(dl/2)**2+Math.cos(p1)*Math.cos(p2)*Math.sin(dg/2)**2;
 return 6371*2*Math.atan2(Math.sqrt(z),Math.sqrt(Math.max(0,1-z)));
}
function roundMoney(n){return Math.round((n+Number.EPSILON)*100)/100;}
function newPin(){return String(crypto.randomInt(0,10000)).padStart(4,"0");}

const createCustomerRide=onCall({region:"asia-south1",maxInstances:100},async request=>{
 const uid=request.auth?.uid;
 if(!uid)throw new HttpsError("unauthenticated","Sign in before booking a ride.");
 const clientRequestId=String(request.data?.clientRequestId||"").trim();
 if(!/^[A-Za-z0-9_-]{6,100}$/.test(clientRequestId))throw new HttpsError("invalid-argument","A valid request ID is required.");
 const type=String(request.data?.rideType||"").trim().toLowerCase();
 if(!["bike","auto","car"].includes(type))throw new HttpsError("invalid-argument","Choose a valid ride type.");
 const pickupLat=numberOr(request.data?.pickupLatitude,NaN),pickupLng=numberOr(request.data?.pickupLongitude,NaN);
 const destLat=numberOr(request.data?.destinationLatitude,NaN),destLng=numberOr(request.data?.destinationLongitude,NaN);
 const validPoint=(lat,lng)=>Number.isFinite(lat)&&Number.isFinite(lng)&&lat>=-90&&lat<=90&&lng>=-180&&lng<=180;
 if(!validPoint(pickupLat,pickupLng)||!validPoint(destLat,destLng))throw new HttpsError("invalid-argument","Valid pickup and destination coordinates are required.");
 const pickupAddress=safeText(request.data?.pickupAddress,400,"Pickup address",true);
 const destinationAddress=safeText(request.data?.destinationAddress,400,"Destination address",true);
 const customerName=safeText(request.data?.customerName,80,"Customer name");
 const customerPhone=String(request.data?.customerPhone||"").replace(/\D/g,"").slice(0,10);
 if(customerPhone.length!==10)throw new HttpsError("invalid-argument","A valid 10-digit phone number is required.");
 const pickupPincode=String(request.data?.pickupPincode||"").replace(/\D/g,"").slice(0,6);
 const destinationPincode=String(request.data?.destinationPincode||"").replace(/\D/g,"").slice(0,6);
 const profileRef=db.collection("customers").doc(uid);
 const settingsRef=db.collection("settings").doc("ridePricing");
 const idemRef=db.collection("rideIdempotency").doc(crypto.createHash("sha256").update(uid+":"+clientRequestId).digest("hex"));
 const rateRef=db.collection("serverRateLimits").doc(crypto.createHash("sha256").update(uid+":ride_booking").digest("hex"));
 const requestId="RIDE"+crypto.randomBytes(7).toString("hex").toUpperCase();
 const rideRef=db.collection("autoRideRequests").doc(requestId);
 const pinRef=db.collection("customerPrivatePins").doc("ride_"+requestId);
 const createdAt=FieldValue.serverTimestamp();

 const result=await db.runTransaction(async tx=>{
  const idem=await tx.get(idemRef);
  if(idem.exists){
   const existingId=String(idem.data()?.requestId||"");
   const existing=existingId?await tx.get(db.collection("autoRideRequests").doc(existingId)):null;
   if(existing?.exists)return {requestId:existingId,estimatedFare:Number(existing.data()?.estimatedFare||0),distanceKm:Number(existing.data()?.distanceKm||0),alreadyPlaced:true};
   throw new HttpsError("failed-precondition","The earlier ride request is unavailable. Contact support.");
  }
  const rateSnap=await tx.get(rateRef);
  const nowMs=Date.now(),rate=rateSnap.data()||{},rateStart=Number(rate.windowStartedAtMs||0);
  const activeWindow=nowMs-rateStart<10*60*1000;
  const used=activeWindow?Math.max(0,Number(rate.count||0)):0;
  if(used>=8)throw new HttpsError("resource-exhausted","Too many ride requests. Please wait a few minutes before trying again.");
  const [profileSnap,settingsSnap]=await Promise.all([tx.get(profileRef),tx.get(settingsRef)]);
  const profile=profileSnap.data()||{},settings=settingsSnap.data()||{};
  const configured=settings[type]&&typeof settings[type]==="object"?settings[type]:{};
  const distance=distanceKm(pickupLat,pickupLng,destLat,destLng);
  const roadMultiplier=Math.max(1,Math.min(2.5,numberOr(settings.roadDistanceMultiplier,1.25)));
  const pricedDistance=roundMoney(distance*roadMultiplier);
  const legacyBase=type==="bike"?20:(type==="auto"?30:50);
  const legacyPer=type==="bike"?8:(type==="auto"?12:16);
  const legacyMinimum=type==="bike"?30:(type==="auto"?40:60);
  const hasConfigured=Object.keys(configured).length>0;
  const within5=Math.max(0,numberOr(configured.within5Km,legacyMinimum));
  const above5=Math.max(0,numberOr(configured.above5KmRate,legacyPer));
  const fare=roundMoney(hasConfigured
    ? (pricedDistance<=5?within5:within5+((pricedDistance-5)*above5))
    : (pricedDistance<=0?legacyMinimum:Math.max(legacyMinimum,legacyBase+pricedDistance*legacyPer)));
  if(settings.rideBookingEnabled===false)throw new HttpsError("failed-precondition","Ride booking is temporarily unavailable.");
  if(pickupPincode){
   const zoneSnap=await tx.get(db.collection("serviceableZones").doc(pickupPincode));
   if(!zoneSnap.exists||String(zoneSnap.data()?.status||"").toLowerCase()!=="serviceable"){
    throw new HttpsError("failed-precondition","The pickup PIN code is not currently serviceable.");
   }
  }

  tx.set(rideRef,{
   customerUid:uid,
   customerName:customerName||profile.displayName||profile.name||String(request.auth.token.name||"ALLways customer"),
   customerPhone:customerPhone||String(profile.phone||profile.mobileNumber||""),
   rideType:type,
   status:"searching",
   pickupLatitude:pickupLat,
   pickupLongitude:pickupLng,
   pickupAddress,
   pickupPincode,
   destination:destinationAddress,
   destinationAddress,
   destinationLatitude:destLat,
   destinationLongitude:destLng,
   destinationPincode,
   distanceKm:pricedDistance,
   straightLineDistanceKm:distance,
   etaMinutes:Math.max(1,Math.ceil(pricedDistance/25*60)),
   estimatedFare:fare,
   pricingModel:hasConfigured?"server_admin_tiered_5km":"server_legacy_fallback",
   pricingWithin5Km:hasConfigured?within5:null,
   pricingAbove5KmRate:hasConfigured?above5:null,
   rejectedBy:[],
   ridePinVerified:false,
   customerActive:true,
   expiresAt:new Date(Date.now()+30*60*1000),
   createdAt,
   updatedAt:createdAt,
   source:"customer_android",
  });
  tx.set(pinRef,{
   customerUid:uid,recordId:requestId,type:"ride",confirmationPin:newPin(),
   attempts:0,createdAt,expiresAt:new Date(Date.now()+30*24*60*60*1000),
  });
  tx.set(idemRef,{customerUid:uid,clientRequestId,requestId,createdAt,expiresAt:new Date(Date.now()+48*60*60*1000)});
  tx.set(rateRef,{count:used+1,windowStartedAtMs:activeWindow?rateStart:nowMs,expiresAt:new Date(nowMs+60*60*1000),updatedAt:createdAt});
  return {requestId,estimatedFare:fare,distanceKm:pricedDistance,alreadyPlaced:false};
 });
 return {ok:true,...result};
});

module.exports={createCustomerRide};
