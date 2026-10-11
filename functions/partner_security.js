"use strict";
const crypto=require("crypto");
const {getFirestore,FieldValue}=require("firebase-admin/firestore");
const {onCall,HttpsError}=require("firebase-functions/v2/https");
const {onSchedule}=require("firebase-functions/v2/scheduler");
const db=getFirestore();

const collectionFor=role=>role==="carrier"?"ridePartners":role==="delivery_partner"?"deliveryPartners":null;
const terminal=s=>["completed","delivered","cancelled","rejected","expired"].includes(String(s||"").trim().toLowerCase());
const clearLocation=role=>Object.fromEntries((role==="carrier"
 ?["carrierLat","carrierLng","carrierLocationUpdatedAt","lastLocationAt"]
 :["deliveryLat","deliveryLng","lastLat","lastLng","deliveryLocationUpdatedAt","lastLocationAt"]
).map(k=>[k,FieldValue.delete()]));

async function requireNoActiveWork(tx,role,p){
 if(role==="carrier"){
  const id=String(p.activeRideId||"").trim();
  if(id){const s=await tx.get(db.collection("autoRideRequests").doc(id));if(s.exists&&!terminal(s.data()?.status))throw new HttpsError("failed-precondition","Complete or resolve your active ride before ending your shift.");}
  else if(String(p.status||"").toLowerCase()==="on_trip")throw new HttpsError("failed-precondition","An active ride is still recorded. Contact support before ending your shift.");
 }else{
  const id=String(p.currentOrderId||"").trim();
  if(id){const s=await tx.get(db.collection("orders").doc(id));if(s.exists&&!terminal(s.data()?.status))throw new HttpsError("failed-precondition","Complete or resolve your active delivery before ending your shift.");}
 }
}

const setPartnerShift=onCall({region:"asia-south1",maxInstances:50},async request=>{
 const uid=request.auth?.uid;if(!uid)throw new HttpsError("unauthenticated","Sign-in is required.");
 const role=String(request.data?.role||"").trim().toLowerCase(), online=request.data?.online, collection=collectionFor(role);
 if(!collection||typeof online!=="boolean")throw new HttpsError("invalid-argument","A valid partner role and shift state are required.");
 const ref=db.collection(collection).doc(uid), newId=online?crypto.randomUUID():null;
 return db.runTransaction(async tx=>{
  const snap=await tx.get(ref);if(!snap.exists)throw new HttpsError("failed-precondition","Partner profile not found.");
  const p=snap.data()||{};
  if(String(p.approvalStatus||"").toLowerCase()!=="approved")throw new HttpsError("permission-denied","Admin approval is required before starting a shift.");
  if(["suspended","blocked","disabled"].includes(String(p.accountStatus||"").toLowerCase()))throw new HttpsError("permission-denied","This partner account is not allowed to work.");
  const onDuty=String(p.shiftStatus||"").toLowerCase()==="on_duty";
  if(online&&onDuty&&String(p.shiftSessionId||"").trim()){
   tx.update(ref,{locationTrackingActive:true,lastSeenAt:FieldValue.serverTimestamp(),trackingAttentionRequired:false});
   return {ok:true,shiftSessionId:String(p.shiftSessionId),alreadyOnDuty:true};
  }
  if(!online){
   await requireNoActiveWork(tx,role,p);
   const pendingOrderId=role==="delivery_partner"?String(p.pendingOrderId||"").trim():"";
   if(pendingOrderId&&pendingOrderId!==String(p.currentOrderId||"").trim()){
    const pendingRef=db.collection("orders").doc(pendingOrderId);
    const pendingSnap=await tx.get(pendingRef);
    if(pendingSnap.exists){
     const pending=pendingSnap.data()||{};
     const assignedUid=String(pending.carrierUid||pending.deliveryPartnerUid||pending.assignedPartnerId||"").trim();
     if(assignedUid===uid&&String(pending.status||"").toLowerCase()==="pending_acceptance"){
      tx.update(pendingRef,{carrierUid:null,deliveryPartnerUid:null,assignedPartnerId:null,carrierName:null,carrierPhone:null,carrierAccepted:false,status:"New Order",assignmentStatus:"waiting_for_partner",statusNote:"The delivery partner ended their shift before accepting the offer.",updatedAt:FieldValue.serverTimestamp()});
     }
    }
   }
   const now=FieldValue.serverTimestamp();
   tx.update(ref,{status:"offline",dutyStatus:"offline",shiftStatus:"off_duty",locationTrackingActive:false,availableForRides:false,availableForDeliveries:false,isOnline:false,shiftEndedAt:now,statusUpdatedAt:now,shiftSessionId:FieldValue.delete(),trackingAttentionRequired:false,...clearLocation(role)});
   return {ok:true,shiftSessionId:null,alreadyOffDuty:!onDuty};
  }
  const status=String(p.status||"").toLowerCase();
  if(["on_trip","on_delivery"].includes(status)||String(p.activeRideId||p.currentOrderId||"").trim())throw new HttpsError("failed-precondition","An active job already exists. Resume it instead of starting a new shift.");
  const now=FieldValue.serverTimestamp();
  tx.update(ref,{status:"online",dutyStatus:"online",shiftStatus:"on_duty",locationTrackingActive:true,availableForRides:role==="carrier",availableForDeliveries:role==="delivery_partner",isOnline:true,shiftSessionId:newId,shiftStartedAt:now,lastSeenAt:now,shiftEndedAt:FieldValue.delete(),trackingAttentionRequired:false,statusUpdatedAt:now});
  return {ok:true,shiftSessionId:newId,alreadyOnDuty:false};
 });
});

const acceptRide=onCall({region:"asia-south1",maxInstances:100},async request=>{
 const uid=request.auth?.uid;if(!uid)throw new HttpsError("unauthenticated","Sign-in is required.");
 const id=String(request.data?.rideId||"").trim();if(!id)throw new HttpsError("invalid-argument","Ride ID is required.");
 const rr=db.collection("autoRideRequests").doc(id),pr=db.collection("ridePartners").doc(uid);
 return db.runTransaction(async tx=>{
  const [rs,ps]=await Promise.all([tx.get(rr),tx.get(pr)]);
  if(!rs.exists)throw new HttpsError("not-found","Ride request not found.");
  if(!ps.exists)throw new HttpsError("failed-precondition","Driver profile not found.");
  const r=rs.data()||{},p=ps.data()||{};
  if(String(p.approvalStatus||"").toLowerCase()!=="approved"||String(p.shiftStatus||"").toLowerCase()!=="on_duty"||p.locationTrackingActive===false)throw new HttpsError("failed-precondition","An approved driver with an active shift is required.");
  if(String(p.activeRideId||"").trim()||String(p.status||"").toLowerCase()==="on_trip")throw new HttpsError("failed-precondition","Complete your current ride before accepting another.");
  const assigned=String(r.driverUid||r.carrierUid||"").trim();
  if(assigned===uid&&String(r.status||"").toLowerCase()==="accepted")return {ok:true,rideId:id,alreadyAccepted:true};
  if(String(r.status||"").toLowerCase()!=="searching"||assigned)throw new HttpsError("aborted","This ride has already been accepted or is no longer available.");
  const expires=r.expiresAt?.toMillis?r.expiresAt.toMillis():0;if(expires&&expires<=Date.now())throw new HttpsError("deadline-exceeded","This ride request has expired.");
  const target=String(r.rideType||"bike").toLowerCase(),raw=String(p.vehicleType||"bike").toLowerCase(),vehicle=["two_wheeler","motorcycle","scooter"].includes(raw)?"bike":(["cab","sedan","hatchback"].includes(raw)?"car":raw);
  if(target!==vehicle)throw new HttpsError("failed-precondition","This ride is for a different vehicle type.");
  const now=FieldValue.serverTimestamp();
  tx.update(rr,{status:"accepted",driverUid:uid,driverName:p.name||p.displayName||request.auth.token.name||"ALLways Driver Partner",driverPhone:p.phone||p.mobileNumber||request.auth.token.phone_number||"",driverVehicleType:vehicle,acceptedAt:now,updatedAt:now});
  tx.update(pr,{status:"on_trip",availableForRides:false,activeRideId:id,statusUpdatedAt:now,locationTrackingActive:true});
  tx.set(db.collection("rideOffers").doc(uid).collection("requests").doc(id), {
    status:"accepted", acceptedAt:now, rejected:false
  }, {merge:true});
  return {ok:true,rideId:id};
 });
});

const acceptDeliveryOrder=onCall({region:"asia-south1",maxInstances:100},async request=>{
 const uid=request.auth?.uid;if(!uid)throw new HttpsError("unauthenticated","Sign-in required.");
 const id=String(request.data?.orderId||request.data?.id||"").trim();if(!id)throw new HttpsError("invalid-argument","Order ID is required.");
 const or=db.collection("orders").doc(id),pr=db.collection("deliveryPartners").doc(uid);
 return db.runTransaction(async tx=>{
  const [os,ps]=await Promise.all([tx.get(or),tx.get(pr)]);
  if(!os.exists)throw new HttpsError("not-found","Order not found.");
  if(!ps.exists)throw new HttpsError("failed-precondition","Delivery partner profile missing.");
  const o=os.data()||{},p=ps.data()||{},status=String(o.status||"").trim().toLowerCase();
  if(String(p.approvalStatus||"").toLowerCase()!=="approved"||String(p.shiftStatus||"").toLowerCase()!=="on_duty"||p.locationTrackingActive===false)throw new HttpsError("failed-precondition","Admin approval and an active shift are required.");
  const assigned=String(o.carrierUid||o.deliveryPartnerUid||o.deliveryPartnerId||o.assignedPartnerId||"").trim();
  if(assigned===uid&&status==="assigned") {
   tx.update(pr,{status:"on_delivery",dutyStatus:"on_delivery",availableForDeliveries:false,currentOrderId:id,pendingOrderId:FieldValue.delete(),statusUpdatedAt:FieldValue.serverTimestamp(),locationTrackingActive:true});
   return {ok:true,orderId:id,alreadyAccepted:true};
  }
  if(assigned&&assigned!==uid)throw new HttpsError("aborted","This order is assigned to another partner.");
  if(!["new order","searching","ready","pending","pending_acceptance","assigned",""].includes(status))throw new HttpsError("failed-precondition","This order is no longer available.");
  if(String(p.currentOrderId||"").trim())throw new HttpsError("failed-precondition","Complete your current delivery before accepting another.");
  const now=FieldValue.serverTimestamp();
  tx.update(or,{carrierUid:uid,deliveryPartnerUid:uid,assignedPartnerId:uid,carrierName:p.name||p.displayName||"ALLways Delivery Partner",carrierPhone:p.phone||p.mobileNumber||"",carrierVehicleType:p.vehicleType||"bike",status:"Assigned",carrierAccepted:true,assignedAt:now,updatedAt:now});
  tx.update(pr,{status:"on_delivery",dutyStatus:"on_delivery",availableForDeliveries:false,currentOrderId:id,pendingOrderId:FieldValue.delete(),statusUpdatedAt:now,locationTrackingActive:true});
  return {ok:true,orderId:id};
 });
});

const updateDeliveryOrderStatus=onCall({region:"asia-south1",maxInstances:100},async request=>{
 const uid=request.auth?.uid;if(!uid)throw new HttpsError("unauthenticated","Sign-in required.");
 const id=String(request.data?.orderId||request.data?.id||"").trim(),key=String(request.data?.status||"").trim().toLowerCase();
 if(!id)throw new HttpsError("invalid-argument","Order ID is required.");
 const normalized={"assigned":"Assigned","pending_acceptance":"Assigned","picked up":"Picked Up","picked_up":"Picked Up","out for delivery":"Out for delivery","out_for_delivery":"Out for delivery","arrived":"Arrived"}[key];
 if(!normalized)throw new HttpsError("invalid-argument","Unsupported delivery status.");
 const or=db.collection("orders").doc(id),pr=db.collection("deliveryPartners").doc(uid);
 return db.runTransaction(async tx=>{
  const [os,ps]=await Promise.all([tx.get(or),tx.get(pr)]);
  if(!os.exists)throw new HttpsError("not-found","Order not found.");if(!ps.exists)throw new HttpsError("failed-precondition","Delivery partner profile missing.");
  const o=os.data()||{},p=ps.data()||{},assigned=String(o.carrierUid||o.deliveryPartnerUid||o.deliveryPartnerId||o.assignedPartnerId||"");
  if(assigned!==uid)throw new HttpsError("permission-denied","This delivery is not assigned to you.");
  if(String(p.approvalStatus||"").toLowerCase()!=="approved"||String(p.shiftStatus||"").toLowerCase()!=="on_duty")throw new HttpsError("failed-precondition","An approved active shift is required.");
  const current=String(o.status||"").trim().toLowerCase(),transitions={"assigned":["picked up"],"pending_acceptance":["picked up"],"picked up":["out for delivery"],"out for delivery":["arrived"],"arrived":[]};
  const requested=key==="picked_up"?"picked up":key;
  if(!(transitions[current]||[]).includes(requested))throw new HttpsError("failed-precondition","Delivery status transition is not allowed.");
  const now=FieldValue.serverTimestamp(),patch={status:normalized,updatedAt:now,updatedBy:uid,statusNote:"Updated by ALLways Delivery Partner"};
  if(normalized==="Picked Up")patch.pickedUpAt=now;if(normalized==="Out for delivery")patch.outForDeliveryAt=now;if(normalized==="Arrived")patch.arrivedAt=now;
  tx.update(or,patch);tx.update(pr,{currentOrderId:id,status:"on_delivery",dutyStatus:"on_delivery",availableForDeliveries:false,statusUpdatedAt:now});
  return {ok:true,orderId:id,status:normalized};
 });
});

const expireStalePartnerShifts=onSchedule(
 {schedule:"every 5 minutes",timeZone:"Asia/Kolkata",region:"asia-south1",maxInstances:1},
 async()=>{
  const cutoff=Date.now()-10*60*1000;
  for(const [collection,role] of [["ridePartners","carrier"],["deliveryPartners","delivery_partner"]]){
   const snap=await db.collection(collection).where("shiftStatus","==","on_duty").where("lastSeenAt","<",new Date(cutoff)).orderBy("lastSeenAt","asc").limit(400).get();
   if(snap.empty)continue;
   const batch=db.batch(),now=FieldValue.serverTimestamp();
   for(const d of snap.docs){
    const p=d.data()||{},id=String(role==="carrier"?p.activeRideId||"":p.currentOrderId||"").trim();
    const jobRef=id?db.collection(role==="carrier"?"autoRideRequests":"orders").doc(id):null;
    let active=false;
    if(jobRef){const job=await jobRef.get();active=job.exists&&!terminal(job.data()?.status);}
    if(active){
     if(p.locationTrackingActive!==false||p.trackingAttentionRequired!==true){
      batch.update(d.ref,{locationTrackingActive:false,trackingAttentionRequired:true,...clearLocation(role)});
      batch.update(jobRef,role==="carrier"?{driverLat:FieldValue.delete(),driverLng:FieldValue.delete(),driverLocationUpdatedAt:FieldValue.delete()}:{carrierLat:FieldValue.delete(),carrierLng:FieldValue.delete(),carrierLocationUpdatedAt:FieldValue.delete()});
     }
    }else{
     batch.update(d.ref,{status:"offline",dutyStatus:"offline",shiftStatus:"off_duty",locationTrackingActive:false,availableForRides:false,availableForDeliveries:false,isOnline:false,shiftSessionId:FieldValue.delete(),shiftEndedAt:now,statusUpdatedAt:now,trackingAttentionRequired:true,...clearLocation(role)});
    }
   }
   await batch.commit();
  }
 }
);

module.exports={setPartnerShift,acceptRide,acceptDeliveryOrder,updateDeliveryOrderStatus,expireStalePartnerShifts};
