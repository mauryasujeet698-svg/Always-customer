/* =========================================================
   LIVE INVENTORY STATE
   ========================================================= */

let products = [];
let cats = ["All"];
let inventoryLoaded = false;


/* =========================================================
   FIREBASE CONFIGURATION
   ========================================================= */

const FIREBASE_CONFIG = {
  apiKey: "AIzaSyCopzTF-jwLnzcbCnW5Y9nIHYMkiinaZ28",
  authDomain: "allways-web.firebaseapp.com",
  projectId: "allways-web",
  storageBucket: "allways-web.firebasestorage.app",
  messagingSenderId: "869987297351",
  appId: "1:869987297351:web:fde91fb46194a141976962",
  measurementId: "G-1N2DFFC7BT"
};


/* =========================================================
   BUSINESS SETTINGS
   ========================================================= */

const CONFIG = {
  freeDeliveryThreshold: 499,
  standardDeliveryFee: 30,
  /* GOOGLE APPS SCRIPT WEB APP */
  orderEndpoint: "https://script.google.com/macros/s/AKfycbyuAdL6eEIlGiYhoTPFtE70VhyiMLnKgzO1ytctdSCWMtTdw4zIVQvEVwkbYJyJF2Wd/exec"
};


/* =========================================================
   APP STATE
   ========================================================= */

let cart = {};
let selectedCat = "All";
let currentUser = null;
let firebaseReady = false;
let db = null;
let customerOrdersUnsubscribe = null;
let announcementsUnsubscribe = null;
let savedAddresses = [];
let favouriteIds = new Set();
let favouritesOnly = false;
const ADMIN_EMAIL = "mauryasujeet698@gmail.com";
// Add the Firebase Web Push public VAPID key here to enable background browser notifications.
const WEB_PUSH_VAPID_KEY = "";
let orders = [];

try {
  orders = JSON.parse(localStorage.getItem("allwaysOrders") || "[]");
} catch(e) {
  orders = [];
}


/* =========================================================
   FETCH INVENTORY FROM GOOGLE SHEETS
   ========================================================= */

async function loadInventory(){
  inventoryLoaded = false;
  renderProducts();

  function normalizeProduct(raw, fallbackId){
    const p = raw || {};
    const id = String(p.id ?? p.ID ?? fallbackId ?? "").trim();
    const name = String(p.name ?? p.title ?? p["Product Name"] ?? "").trim();
    const category = String(p.category ?? p.cat ?? p.Category ?? "Other").trim() || "Other";
    const emoji = String(p.emoji ?? p.icon ?? p.Emoji ?? "🛒").trim() || "🛒";
    const imageUrl = String(p.imageUrl ?? p.imageURL ?? p["Image URL"] ?? "").trim();
    const price = Number(p.price ?? p.Price ?? 0) || 0;
    const stock = Math.max(0, Number(p.stock ?? p.Stock ?? 0) || 0);
    const maxQty = Math.max(1, Number(p.maxQty ?? p["Max Qty"] ?? 10) || 10);
    const availableRaw = p.available ?? p.Available;
    const available = typeof availableRaw === "boolean"
      ? availableRaw
      : !["no", "false", "0", "unavailable"].includes(
          String(availableRaw ?? "yes").trim().toLowerCase()
        );

    return {
      id: id || name,
      name,
      title: name,
      category,
      cat: category,
      emoji,
      icon: emoji,
      imageUrl,
      price,
      stock: available ? stock : 0,
      available,
      maxQty
    };
  }

  try {
    // Primary source: Firestore products/{id}. The Admin app syncs the
    // Google Sheet into the same Firebase project.
    if(db){
      const snapshot = await db.collection("products").get();
      const firestoreProducts = snapshot.docs
        .map(function(doc){
          return normalizeProduct(doc.data(), doc.id);
        })
        .filter(function(p){ return p.name; });

      if(firestoreProducts.length){
        products = firestoreProducts;
        cats = ["All"].concat(
          Array.from(new Set(products.map(function(p){ return p.cat; })))
        );
        inventoryLoaded = true;
        renderCats();
        renderProducts();
        console.log(
          "ALLways: loaded " + products.length + " products from Firestore."
        );
        return;
      }
    }

    // Fallback: the same live Google Apps Script endpoint used by Admin.
    const endpoint =
      "https://script.google.com/macros/s/AKfycbxnmGS7Q6t7pPWiT50V87JmA0Qbh2tSi1UKLFzN28dQpybjw7vvCufnryi-qpTnq0b0IA/exec";
    const response = await fetch(
      endpoint + "?_=" + Date.now(),
      { cache: "no-store" }
    );
    if(!response.ok){
      throw new Error("Catalog endpoint returned HTTP " + response.status + ".");
    }

    const data = await response.json();
    const fetchedProducts = Array.isArray(data.products)
      ? data.products
      : (Array.isArray(data) ? data : []);

    products = fetchedProducts
      .map(function(p){ return normalizeProduct(p, p.ID); })
      .filter(function(p){ return p.name; });

    cats = ["All"].concat(
      Array.from(new Set(products.map(function(p){ return p.cat; })))
    );
    inventoryLoaded = products.length > 0;
    renderCats();
    renderProducts();

    console.log(
      "ALLways: loaded " + products.length + " products from catalog fallback."
    );
  } catch (error) {
    products = [];
    cats = ["All"];
    inventoryLoaded = false;
    renderCats();
    renderProducts();
    console.error("ALLways inventory load failed:", error);
  }
}

/* =========================================================
   SAFE HTML
   ========================================================= */

function escapeHtml(value){
  return String(value ?? "").replace(/[&<>'"]/g, function(c){
    return {"&":"&amp;", "<":"&lt;", ">":"&gt;", "'":"&#39;", '"':"&quot;"}[c];
  });
}


/* =========================================================
   SHOP
   ========================================================= */

function renderCats(){
  const el = document.getElementById("categories");
  if(!el) return;

  el.innerHTML = cats.map(function(c){
    return `<button class="cat ${c === selectedCat ? "active" : ""}" data-cat="${escapeHtml(c)}">${escapeHtml(c)}</button>`;
  }).join("");

  // Event delegation instead of inline onclick strings — avoids any
  // HTML-entity-decoding edge cases with special characters in category names.
  el.querySelectorAll(".cat").forEach(function(btn){
    btn.addEventListener("click", function(){
      setCat(btn.dataset.cat);
    });
  });
}

function loadCustomerPreferences(){
  if(!currentUser) return;
  try {
    savedAddresses=JSON.parse(localStorage.getItem("allwaysAddresses_"+currentUser.uid)||"[]");
    favouriteIds=new Set(JSON.parse(localStorage.getItem("allwaysFavourites_"+currentUser.uid)||"[]"));
  } catch(e){savedAddresses=[];favouriteIds=new Set();}
}
function saveCustomerPreferences(){
  if(!currentUser) return;
  try{
    localStorage.setItem("allwaysAddresses_"+currentUser.uid,JSON.stringify(savedAddresses));
    localStorage.setItem("allwaysFavourites_"+currentUser.uid,JSON.stringify(Array.from(favouriteIds)));
  }catch(e){}
}
function toggleFavourite(id){
  if(!currentUser){openAuth("Please sign in to save favourite products.");return;}
  const key=String(id); if(favouriteIds.has(key)) favouriteIds.delete(key); else favouriteIds.add(key);
  saveCustomerPreferences(); renderProducts();
}
function reorderOrder(orderId){
  const order=orders.find(function(o){return o.id===orderId;}); if(!order||!order.items)return;
  let skipped=[];
  order.items.forEach(function(item){
    const p=products.find(function(x){return String(x.id)===String(item.id);});
    if(!p||p.stock<1){skipped.push(item.name);return;}
    cart[p.id]=Math.min(p.stock,(cart[p.id]||0)+Number(item.qty||1));
  });
  updateCart();renderProducts();showSection("shop");
  if(skipped.length)alert("Some items are unavailable: "+skipped.join(", "));
}
function saveAddressFromCheckout(){
  if(!currentUser)return;
  const n=document.getElementById("customerName"),ph=document.getElementById("phone"),a=document.getElementById("address");
  const name=n?.value.trim(),phone=ph?.value.trim().replace(/\D/g,""),address=a?.value.trim();
  if(!name||!/^\d{10}$/.test(phone||"")||!address)return;
  if(!savedAddresses.some(function(x){return x.address.toLowerCase()===address.toLowerCase();})){
    savedAddresses.unshift({id:"ADDR"+Date.now(),name:name,phone:phone,address:address});
    savedAddresses=savedAddresses.slice(0,5);saveCustomerPreferences();
  }
}
function chooseSavedAddress(id){
  const a=savedAddresses.find(function(x){return x.id===id;});if(!a)return;
  const n=document.getElementById("customerName"),p=document.getElementById("phone"),ad=document.getElementById("address");
  if(n)n.value=a.name||"";if(p)p.value=a.phone||"";if(ad)ad.value=a.address||"";
}
function renderProducts(){
  const search = document.getElementById("search");
  const productsEl = document.getElementById("products");
  const count = document.getElementById("count");

  if(!productsEl) return;

  const q=search?search.value.toLowerCase().trim():"";
  const terms=q.split(/\s+/).filter(Boolean);
  const list=products.filter(function(p){
    const haystack=[p.name,p.cat,p.description,p.brand].filter(Boolean).join(" ").toLowerCase();
    const categoryMatch=selectedCat==="All"||p.cat===selectedCat;
    const searchMatch=!terms.length||terms.every(function(t){return haystack.includes(t);});
    const favouriteMatch=!favouritesOnly||favouriteIds.has(String(p.id));
    return categoryMatch&&searchMatch&&favouriteMatch;
  });

  if(count){
    count.textContent = list.length + " shown";
  }

  if(!list.length){
    productsEl.innerHTML = `<div class="empty">${inventoryLoaded ? "No matching items." : "Loading inventory…"}</div>`;
    return;
  }

  productsEl.innerHTML = list.map(function(p){
    return `
      <article class="product">
        <div class="pic">${escapeHtml(p.icon)}</div>
        <h3>${escapeHtml(p.name)}</h3>
        <small>${escapeHtml(p.cat)}</small>
        <button type="button" class="favBtn ${favouriteIds.has(String(p.id)) ? "saved" : ""}" data-fav-id="${escapeHtml(String(p.id))}">${favouriteIds.has(String(p.id)) ? "♥" : "♡"}</button>
        <div class="price">₹${p.price}</div>
        <div class="stock">${p.stock > 0 ? "● In stock" : "● Unavailable"}</div>
        ${cart[p.id] ? `
        <div class="productQty">
          <button type="button" data-qty-id="${escapeHtml(String(p.id))}" data-qty-delta="-1">−</button>
          <b>${cart[p.id]}</b>
          <button type="button" data-qty-id="${escapeHtml(String(p.id))}" data-qty-delta="1">+</button>
          <button type="button" class="removeMini" data-remove-id="${escapeHtml(String(p.id))}" title="Remove item">🗑</button>
        </div>
      ` : `
        <button class="add" data-id="${escapeHtml(String(p.id))}" ${p.stock < 1 ? "disabled" : ""}>
          ${p.stock < 1 ? "Unavailable" : "Add"}
        </button>
      `}
      </article>
    `;
  }).join("");

  productsEl.querySelectorAll("[data-fav-id]").forEach(function(btn){btn.addEventListener("click",function(){toggleFavourite(btn.dataset.favId);});});
  productsEl.querySelectorAll(".add").forEach(function(btn){
    btn.addEventListener("click", function(){
      add(btn.dataset.id);
    });
  });
  productsEl.querySelectorAll("[data-qty-id]").forEach(function(btn){
    btn.addEventListener("click", function(){
      changeQty(btn.dataset.qtyId, Number(btn.dataset.qtyDelta));
    });
  });
  productsEl.querySelectorAll("[data-remove-id]").forEach(function(btn){
    btn.addEventListener("click", function(){
      removeFromCart(btn.dataset.removeId);
    });
  });
}

function setCat(category){
  favouritesOnly=false;
  selectedCat = category;
  const title = document.getElementById("categoryTitle");
  if(title){
    title.textContent = category === "All" ? "All items" : category;
  }
  renderCats();
  renderProducts();
}


/* =========================================================
   CART
   ========================================================= */

function add(id){
  if(!inventoryLoaded){
    alert("Inventory is still loading — please try again in a moment.");
    return;
  }
  if(!currentUser){
    openAuth("Please sign in or create an account before adding items to your cart.");
    return;
  }
  const product = products.find(function(p){ return p.id == id; });
  if(!product || product.stock < 1){ return; }

  const next = (cart[id] || 0) + 1;
  if(next > product.stock){
    alert(`Only ${product.stock} ${product.name} available.`);
    return;
  }

  cart[id] = next;
  updateCart();
  renderProducts();
}

function changeQty(id, delta){
  const product = products.find(function(p){ return p.id == id; });
  if(!product) return;
  const next = (cart[id] || 0) + delta;
  if(next <= 0) delete cart[id];
  else if(next <= product.stock) cart[id] = next;
  else alert("Only " + product.stock + " " + product.name + " available.");
  updateCart();
  renderProducts();
}

function removeFromCart(id){
  delete cart[id];
  updateCart();
  renderProducts();
}

function updateCart(){
  let count = 0;
  let total = 0;

  Object.entries(cart).forEach(function([id, quantity]){
    const product = products.find(function(p){ return p.id == id; });
    if(!product) return;
    count += quantity;
    total += product.price * quantity;
  });

  const cartItems = document.getElementById("cartItems");
  const cartTotal = document.getElementById("cartTotal");
  const cartBar = document.getElementById("cartBar");

  if(cartItems) cartItems.textContent = count + " item" + (count === 1 ? "" : "s");
  if(cartTotal) cartTotal.textContent = "₹" + total;
  if(cartBar) cartBar.classList.toggle("hidden", count === 0);
}


/* =========================================================
   CHECKOUT
   ========================================================= */

function openCheckout(){
  if(!currentUser){
    openAuth("Please sign in to continue to checkout.");
    return;
  }
  if(!Object.keys(cart).length) return;

  let rows = "";
  let subtotal = 0;

  Object.entries(cart).forEach(function([id, quantity]){
    const product = products.find(function(p){ return p.id == id; });
    if(!product) return;
    const itemTotal = product.price * quantity;
    subtotal += itemTotal;
    rows += `
      <div class="checkout-row">
        <span>${escapeHtml(product.name)}</span>
        <div class="qtyControl">
          <button type="button" onclick="changeQty('${escapeHtml(String(id))}', -1)">−</button>
          <b>${quantity}</b>
          <button type="button" onclick="changeQty('${escapeHtml(String(id))}', 1)">+</button>
          <button type="button" class="removeItemBtn" onclick="removeFromCart('${escapeHtml(String(id))}')" title="Remove item">🗑</button>
        </div>
        <b>₹${itemTotal}</b>
      </div>
    `;
  });

  const delivery = subtotal >= CONFIG.freeDeliveryThreshold ? 0 : CONFIG.standardDeliveryFee;
  const total = subtotal + delivery;
  const modalContent = document.getElementById("modalContent");
  const modal = document.getElementById("modal");

  if(!modalContent || !modal) return;

  modalContent.innerHTML = `
    <h2>Complete your order</h2>
    <p class="muted">Signed in as <b>${escapeHtml(currentUser.email)}</b></p>
    ${savedAddresses.length ? '<label>🏠 Saved address<select id="savedAddress" class="field"><option value="">Choose a saved address</option>${savedAddresses.map(function(a){return "<option value=\""+escapeHtml(a.id)+"\">"+escapeHtml(a.name+" — "+a.address.slice(0,55))+"</option>";}).join("")}</select></label>' : ""}
    <p class="muted">Open-box delivery: please check your items before accepting.</p>
    ${rows}
    <div class="checkout-row"><span>Subtotal</span><b>₹${subtotal}</b></div>
    <div class="checkout-row"><span>Delivery</span><b>${delivery ? "₹" + delivery : "FREE 🎉"}</b></div>
    <div class="checkout-total">Total ₹${total}</div>
    <hr>
    <label>👤 Your name<input id="customerName" class="field" placeholder="Full name"></label>
    <label>📞 Phone number<input id="phone" class="field" type="tel" inputmode="tel" placeholder="10-digit mobile number"></label>
    <label>📍 Delivery address<textarea id="address" class="field" rows="3" placeholder="House no., village/area, landmark"></textarea></label>
    <button class="locationBtn" onclick="useCurrentLocation()">📍 Use my current location</button>
    <p id="locationMsg" class="muted"></p>
    <label>📝 Delivery note (optional)<textarea id="note" class="field" rows="2" placeholder="Any landmark or special instruction"></textarea></label>
    <button class="primary" id="placeOrderBtn">Place Order</button>
    <p class="policy">Open-box delivery: if an item is damaged, incorrect, expired, or otherwise not acceptable on inspection, you may reject the affected order at the doorstep without being charged.</p>
  `;

  const savedAddressSelect=document.getElementById("savedAddress");
  if(savedAddressSelect)savedAddressSelect.addEventListener("change",function(){chooseSavedAddress(savedAddressSelect.value);});

  const placeOrderBtn = document.getElementById("placeOrderBtn");
  if(placeOrderBtn){
    placeOrderBtn.addEventListener("click", function(){
      placeOrder(subtotal, delivery, total);
    });
  }

  modal.classList.remove("hidden");
}


/* =========================================================
   CURRENT LOCATION
   ========================================================= */

function useCurrentLocation(){
  const message = document.getElementById("locationMsg");
  if(!message) return;

  if(!navigator.geolocation){
    message.textContent = "Location is not supported on this device. Please enter your address manually.";
    return;
  }
  message.textContent = "Getting your location…";

  navigator.geolocation.getCurrentPosition(
    async function(position){
      const latitude = position.coords.latitude;
      const longitude = position.coords.longitude;
      const address = document.getElementById("address");

      try {
        const response = await fetch(`https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=${latitude}&lon=${longitude}&zoom=18&addressdetails=1`, {headers:{"Accept":"application/json"}});
        const data = await response.json();
        const locationAddress = data.address || {};
        if(address) address.value = data.display_name || `${latitude.toFixed(6)}, ${longitude.toFixed(6)}`;
        message.textContent = `Location found. ${locationAddress.village || locationAddress.town || locationAddress.city || "Area"}`;
      } catch(error) {
        if(address) address.value = `Current location: ${latitude.toFixed(6)}, ${longitude.toFixed(6)}`;
        message.textContent = "Coordinates added. Please add your house number or landmark.";
      }
    },
    function(){
      message.textContent = "Location permission was not granted. Please enter your address manually.";
    },
    {enableHighAccuracy:true, timeout:10000, maximumAge:60000}
  );
}


/* =========================================================
   PLACE ORDER
   ========================================================= */

async function placeOrder(subtotal, delivery, total){
  if(!currentUser){
    openAuth("Please sign in before placing your order.");
    return;
  }

  const nameInput = document.getElementById("customerName");
  const phoneInput = document.getElementById("phone");
  const addressInput = document.getElementById("address");
  const noteInput = document.getElementById("note");

  if(!nameInput || !phoneInput || !addressInput || !noteInput) return;

  const name = nameInput.value.trim();
  const phone = phoneInput.value.trim();
  const address = addressInput.value.trim();
  const note = noteInput.value.trim();

  if(!name || !phone || !address){
    alert("Please enter your name, phone number and delivery address.");
    return;
  }

  const cleanPhone = phone.replace(/\D/g, "");
  if(!/^\d{10}$/.test(cleanPhone)){
    alert("Please enter a valid 10-digit mobile number.");
    return;
  }

  const items = Object.entries(cart).map(function([id, quantity]){
    const product = products.find(function(p){ return p.id == id; });
    return { id: product.id, name: product.name, qty: quantity, price: product.price };
  });

  const order = {
    id: "AW" + Date.now().toString().slice(-7),
    customerId: currentUser.uid,
    email: currentUser.email,
    name: name,
    phone: cleanPhone,
    address: address,
    note: note,
    items: items,
    subtotal: subtotal,
    delivery: delivery,
    total: total,
    paymentMethod: "COD",
    status: "New Order",
    estimatedDelivery: "",
    statusNote: "Order received",
    cancellationReason: "",
    rating: null,
    createdAt: Date.now(),
    updatedAt: Date.now(),
    time: new Date().toLocaleString("en-IN")
  };

  try {
    if(!db) throw new Error("Firestore is not connected.");
    await db.collection("orders").doc(order.id).set(order);
  } catch(error) {
    console.error("ALLways Firestore order save failed:", error);
    alert("Order could not be saved. Please try again. " + (error.code || ""));
    return;
  }

  orders.unshift(order);
  saveAddressFromCheckout();

  try {
    localStorage.setItem("allwaysOrders", JSON.stringify(orders));
  } catch(error) {
    console.log("Could not save order locally.", error);
  }

  /* SEND ORDER TO GOOGLE APPS SCRIPT */
  if(CONFIG.orderEndpoint){
    sendOrderToBackend(order);
  }

  cart = {};
  updateCart();
  closeModal();
  showSection("orders");
  renderOrders();
  showThankYou(order);
}


/* =========================================================
   GOOGLE APPS SCRIPT BACKEND
   ========================================================= */

async function sendOrderToBackend(order){
  try {
    await fetch(CONFIG.orderEndpoint, {
      method: "POST",
      mode: "no-cors",
      headers: { "Content-Type": "text/plain;charset=utf-8" },
      body: JSON.stringify(order)
    });
    console.log("ALLways: order sent to Google Apps Script.");
  } catch(error) {
    console.error("ALLways: Google Apps Script submission failed:", error);
  }
}


/* =========================================================
   THANK YOU
   ========================================================= */

function showThankYou(order){
  const modalContent = document.getElementById("modalContent");
  const modal = document.getElementById("modal");
  if(!modalContent || !modal) return;

  modalContent.innerHTML = `
    <div class="thankyou">
      <div class="successIcon">✓</div>
      <h2>Thank you, ${escapeHtml(order.name)}!</h2>
      <p>Your ALLways order <b>#${escapeHtml(order.id)}</b> has been received.</p>
      <p>We’ll contact you on <b>${escapeHtml(order.phone)}</b> to confirm delivery.</p>
      <div class="thankBox" style="text-align:left">
        <b>Order summary</b><br>
        <span>${(order.items||[]).map(function(i){return escapeHtml(i.name)+" × "+i.qty+" — ₹"+(i.price*i.qty);}).join("<br>")}</span><hr>
        <span>Subtotal: ₹${order.subtotal}</span><br>
        <span>Delivery: ${order.delivery ? "₹"+order.delivery : "FREE"}</span><br>
        <b>Total: ₹${order.total}</b>
      </div>
      <p class="muted">You can track this order anytime from <b>My Orders</b>.</p>
      <button class="primary" id="continueShoppingBtn">Continue shopping</button>
    </div>
  `;

  const continueBtn = document.getElementById("continueShoppingBtn");
  if(continueBtn){
    continueBtn.addEventListener("click", closeModal);
  }

  modal.classList.remove("hidden");
}


function listenToCustomerOrders(){
  if(!db || !currentUser) return;
  customerOrdersUnsubscribe = db.collection("orders")
    .where("customerId", "==", currentUser.uid)
    .onSnapshot(function(snapshot){
      orders = snapshot.docs.map(function(doc){ return doc.data(); });
      orders.sort(function(a,b){ return (b.createdAt || 0) - (a.createdAt || 0); });
      try { localStorage.setItem("allwaysOrders", JSON.stringify(orders)); } catch(e) {}
      renderOrders();
    }, function(error){
      console.error("ALLways customer orders listener:", error);
    });
}


/* =========================================================
   ORDERS
   ========================================================= */

function statusSteps(status){
  const steps=["New Order","Confirmed","Preparing","Out for delivery","Delivered"];
  const current=status==="Cancelled" ? -1 : steps.indexOf(status);
  return steps.map(function(step,i){
    const done=current>=i;
    return '<div class="trackStep '+(done?"done ":"")+(status==="Cancelled"?"cancelAware":"")+'"><span>'+ (done ? "✓" : (i+1)) +'</span><small>'+escapeHtml(step==="New Order"?"Received":step)+'</small></div>';
  }).join("");
}

function canCancelOrder(order){
  return ["New Order","Confirmed"].includes(order.status);
}

async function cancelOrder(orderId){
  const order=orders.find(function(o){return o.id===orderId;});
  if(!order || !canCancelOrder(order)) return;
  const reason=prompt("Why are you cancelling this order?"); if(reason===null)return; const cleanReason=reason.trim(); if(!cleanReason){alert("Please enter a cancellation reason.");return;}
  try{
    await db.collection("orders").doc(orderId).update({
      status:"Cancelled",
      statusNote:"Cancelled by customer",
      cancellationReason:cleanReason,
      updatedAt:Date.now()
    });
  }catch(error){
    alert("Could not cancel the order. Please try again.");
    console.error("ALLways cancel order:",error);
  }
}

async function rateOrder(orderId,rating){ const value=Number(rating); if(value<1||value>5)return; try{await db.collection("orders").doc(orderId).update({rating:value,ratedAt:Date.now()});}catch(error){console.error(error);alert("Could not save your rating. Please try again.");} }

function renderOrders(){
  const ordersList = document.getElementById("ordersList");
  if(!ordersList) return;
  if(!currentUser){
    ordersList.innerHTML = '<div class="empty">Please sign in to view your orders.</div>';
    return;
  }
  const myOrders = orders.filter(function(order){ return order.customerId === currentUser.uid; });
  if(!myOrders.length){
    ordersList.innerHTML = '<div class="empty">No orders yet.</div>';
    return;
  }
  ordersList.innerHTML = myOrders.map(function(order){
    const itemText = (order.items || []).map(function(item){
      return escapeHtml(item.name) + " × " + item.qty;
    }).join(", ");
    const cancelled=order.status==="Cancelled";
    const ratingBlock=order.status==="Delivered" ? (order.rating ? '<div class="ratingDone">⭐ Rated: '+escapeHtml(order.rating)+'/5</div>' : '<div class="rateBox"><b>Rate your order</b><div class="stars"><button class="rateBtn" data-rate-id="'+escapeHtml(order.id)+'" data-rate="1">★</button><button class="rateBtn" data-rate-id="'+escapeHtml(order.id)+'" data-rate="2">★</button><button class="rateBtn" data-rate-id="'+escapeHtml(order.id)+'" data-rate="3">★</button><button class="rateBtn" data-rate-id="'+escapeHtml(order.id)+'" data-rate="4">★</button><button class="rateBtn" data-rate-id="'+escapeHtml(order.id)+'" data-rate="5">★</button></div></div>') : "";
    const reorderButton=order.items&&order.items.length ? '<button class="secondary smallAction reorderBtn" data-reorder-id="'+escapeHtml(order.id)+'">↻ Reorder</button>' : "";
    const cancelButton=canCancelOrder(order)
      ? '<button class="cancelOrderBtn" onclick="cancelOrder(\''+escapeHtml(order.id)+'\')">Cancel order</button>' : '';
    const eta=order.estimatedDelivery
      ? '<div class="etaBox">🚚 <b>Estimated delivery: '+escapeHtml(order.estimatedDelivery)+'</b>'+(order.statusNote?'<small>'+escapeHtml(order.statusNote)+'</small>':'')+'</div>'
      : (order.statusNote ? '<div class="etaBox">ℹ️ '+escapeHtml(order.statusNote)+'</div>' : '');
    return '<div class="orderCard '+(cancelled?"cancelled":"")+'">'+
      '<div class="orderTop"><div><b>#'+escapeHtml(order.id)+'</b><span class="status '+(cancelled?"cancelledStatus":"")+'">'+escapeHtml(order.status)+'</span></div><b>₹'+escapeHtml(order.total)+'</b></div>'+
      '<p>'+itemText+'</p>'+(order.cancellationReason ? '<div class="cancelReason">❌ Cancellation reason: '+escapeHtml(order.cancellationReason)+'</div>' : '')+
      (!cancelled ? '<div class="orderTracker">'+statusSteps(order.status)+'</div>' : '')+
      eta+
      '<small>Placed: '+escapeHtml(order.time)+'</small>'+ratingBlock+'<div class="orderActions"><button class="secondary smallAction" data-support-order="'+escapeHtml(order.id)+'">🎧 Help</button>'+reorderButton+cancelButton+'</div>'+
      '</div>';
  }).join("");
  ordersList.querySelectorAll(".rateBtn").forEach(function(btn){btn.addEventListener("click",function(){rateOrder(btn.dataset.rateId,btn.dataset.rate);});});
  ordersList.querySelectorAll(".reorderBtn").forEach(function(btn){btn.addEventListener("click",function(){reorderOrder(btn.dataset.reorderId);});});
  ordersList.querySelectorAll("[data-support-order]").forEach(function(btn){btn.addEventListener("click",function(){openSupport({area:"Order",orderId:btn.dataset.supportOrder});});});
}


/* =========================================================
   SECTIONS
   ========================================================= */

function showSection(id){
  document.querySelectorAll(".section").forEach(function(section){
    section.classList.add("hidden");
  });
  const target = document.getElementById(id);
  if(target){
    target.classList.remove("hidden");
  }
  document.querySelectorAll(".tab").forEach(function(tab){
    tab.classList.toggle("active", tab.dataset.section === id);
  });
  if(id === "orders"){
    favouritesOnly=false;
    renderOrders();
  }
  if(id === "shop" && !document.getElementById("search")?.value){renderProducts();}
}


/* =========================================================
   TRAVEL
   ========================================================= */

async function travelAction(type){
  if(type!=="ride"){
    const message=document.getElementById("travelMsg");
    if(message)message.textContent="This travel service is not enabled in your area yet.";
    return;
  }
  if(!currentUser){openAuth();return;}
  const modal=document.getElementById("modal"),content=document.getElementById("modalContent");
  if(!modal||!content)return;
  content.innerHTML='<h2>Book a local ride</h2><p class="muted">Allow location access so ALLways can find your pickup point.</p><label>Destination<input id="rideDestination" class="field" placeholder="Enter destination"></label><label>Vehicle<select id="rideType" class="field"><option value="bike">Bike</option><option value="auto">Auto</option><option value="car">Car</option></select></label><button class="primary" id="requestRideBtn">Request ride</button><p id="rideMsg" class="muted auth-msg"></p>';
  modal.classList.remove("hidden");
  document.getElementById("requestRideBtn").addEventListener("click",requestRide);
}
async function requestRide(){
  const msg=document.getElementById("rideMsg"),destination=document.getElementById("rideDestination")?.value.trim(),type=document.getElementById("rideType")?.value||"bike";
  if(!destination){if(msg)msg.textContent="Enter your destination.";return;}
  if(!navigator.geolocation){if(msg)msg.textContent="Location is not available on this device.";return;}
  const btn=document.getElementById("requestRideBtn");if(btn)btn.disabled=true;if(msg)msg.textContent="Finding your pickup location...";
  navigator.geolocation.getCurrentPosition(async function(pos){
    try{
      const lat=pos.coords.latitude,lng=pos.coords.longitude;
      let pickupAddress="Current location",destinationAddress=destination,dlat=null,dlng=null;
      try{
        const r=await fetch("https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat="+lat+"&lon="+lng,{headers:{"Accept":"application/json"}});
        if(r.ok){const x=await r.json();pickupAddress=x.display_name||pickupAddress;}
      }catch(_){}
      try{
        const r=await fetch("https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&q="+encodeURIComponent(destination));
        if(r.ok){const x=await r.json();if(x&&x[0]){dlat=Number(x[0].lat);dlng=Number(x[0].lon);destinationAddress=x[0].display_name||destination;}}
      }catch(_){}
      const ref=db.collection("autoRideRequests").doc();
       const confirmationPin=String(Math.floor(1000+Math.random()*9000));
      await ref.set({
        customerId:currentUser.uid,customerName:currentUser.displayName||currentUser.email||"Customer",customerEmail:currentUser.email||"",
        pickupAddress,destinationAddress,pickupLatitude:lat,pickupLongitude:lng,destinationLatitude:dlat,destinationLongitude:dlng,
        rideType:type,confirmationPin,status:"searching",requestedAt:firebase.firestore.FieldValue.serverTimestamp(),updatedAt:firebase.firestore.FieldValue.serverTimestamp()
      });
      closeModal();showSection("orders");alert("Ride requested. Your 4-digit confirmation number is: "+confirmationPin+"\\n\\nShare this number with your assigned carrier only when they arrive.");
    }catch(e){if(btn)btn.disabled=false;if(msg)msg.textContent="Could not request the ride. Please try again.";}
  },function(){if(btn)btn.disabled=false;if(msg)msg.textContent="Location permission is required to request a ride.";},{enableHighAccuracy:true,timeout:15000,maximumAge:10000});
}


/* =========================================================
   MODALS
   ========================================================= */

function closeModal(){
  const modal = document.getElementById("modal");
  if(modal) modal.classList.add("hidden");
}


/* =========================================================
   FIREBASE AUTHENTICATION
   ========================================================= */

function isAdmin(){ return !!currentUser && String(currentUser.email || "").toLowerCase() === ADMIN_EMAIL.toLowerCase(); }

function firebaseConfigured(){
  return !!(window.firebase && FIREBASE_CONFIG && FIREBASE_CONFIG.apiKey && FIREBASE_CONFIG.projectId);
}

async function setupWebNotifications(user){
  if(!firebaseReady || !("Notification" in window) || !firebase.messaging) return;
  if(!WEB_PUSH_VAPID_KEY) return;
  try{
    const permission=await Notification.requestPermission();
    if(permission!=="granted") return;
    const messaging=firebase.messaging();
    const token=await messaging.getToken({vapidKey:WEB_PUSH_VAPID_KEY});
    if(token){
      await db.collection("fcmTokens").doc(user.uid).collection("tokens").doc(token).set({
        uid:user.uid,token,role:"customer",platform:"web",notificationsEnabled:true,
        updatedAt:firebase.firestore.FieldValue.serverTimestamp()
      },{merge:true});
      await db.collection("fcmTokens").doc(user.uid).set({
        uid:user.uid,token,role:"customer",platform:"web",notificationsEnabled:true,
        updatedAt:firebase.firestore.FieldValue.serverTimestamp()
      },{merge:true});
    }
    messaging.onMessage(function(message){
      const title=message.notification?.title || message.data?.title || "ALLways";
      const body=message.notification?.body || message.data?.body || message.data?.message || "You have a new ALLways update.";
      if(Notification.permission==="granted") new Notification(title,{body});
    });
  }catch(error){ console.warn("ALLways web notifications unavailable:",error); }
}

function initAuth(){
  console.log("ALLways: starting Firebase authentication...");
  if(!firebaseConfigured()){
    firebaseReady = false;
    updateAuthButton();
    console.error("ALLways Firebase SDK was not loaded.");
    return;
  }

  try {
    if(!firebase.apps || firebase.apps.length === 0){
      firebase.initializeApp(FIREBASE_CONFIG);
    }
    const auth = firebase.auth();
    if(!auth) throw new Error("Firebase Auth is unavailable.");
    db = firebase.firestore();

    firebaseReady = true;
    console.log("ALLways Firebase authentication connected.");

    auth.onAuthStateChanged(function(user){
      currentUser = user || null;
      if(currentUser) loadCustomerPreferences(); else {savedAddresses=[];favouriteIds=new Set();}
      console.log("ALLways auth state:", currentUser ? currentUser.email : "signed out");
      updateAuthButton();
      renderOrders();
      if(customerOrdersUnsubscribe){
        customerOrdersUnsubscribe();
        customerOrdersUnsubscribe = null;
      }
      if(!currentUser && announcementsUnsubscribe){
        announcementsUnsubscribe();
        announcementsUnsubscribe = null;
      }
      if(currentUser && db) listenToCustomerOrders();
      if(currentUser && db) listenAnnouncements();
    });
  } catch(error) {
    firebaseReady = false;
    console.error("ALLways Firebase initialization failed:", error);
    updateAuthButton();
  }
}


/* =========================================================
   ANNOUNCEMENTS / NOTIFICATIONS
   ========================================================= */

function showAnnouncementBanner(title, body){
  let banner=document.getElementById("allwaysAnnouncementBanner");
  if(!banner){
    banner=document.createElement("div");
    banner.id="allwaysAnnouncementBanner";
    banner.style.position="fixed";
    banner.style.left="16px";
    banner.style.right="16px";
    banner.style.bottom="16px";
    banner.style.zIndex="9999";
    banner.style.background="#111";
    banner.style.color="#fff";
    banner.style.padding="14px 16px";
    banner.style.borderRadius="14px";
    banner.style.boxShadow="0 8px 28px rgba(0,0,0,.22)";
    document.body.appendChild(banner);
  }
  banner.innerHTML="<b>"+escapeHtml(title)+"</b><div style='margin-top:4px;opacity:.9'>"+escapeHtml(body)+"</div>";
  clearTimeout(window.__allwaysAnnouncementTimer);
  window.__allwaysAnnouncementTimer=setTimeout(function(){
    if(banner)banner.remove();
  },8000);
}

function listenAnnouncements(){
  if(!db||!currentUser)return;
  if(announcementsUnsubscribe)announcementsUnsubscribe();
  announcementsUnsubscribe=db.collection("announcements")
    .orderBy("createdAt","desc")
    .limit(1)
    .onSnapshot(function(snap){
      snap.docChanges().forEach(function(change){
        if(change.type!=="added")return;
        var data=change.doc.data()||{};
        var topic=String(data.topic||data.targetAudience||"all_users");
        if(topic!=="all_users"&&topic!=="customers")return;
        var title=String(data.title||"ALLways");
        var body=String(data.body||"");
        showAnnouncementBanner(title,body);
        if(typeof Notification!=="undefined"&&Notification.permission==="granted"){
          try{new Notification(title,{body:body});}catch(e){}
        }
      });
    },function(error){
      console.warn("ALLways announcements listener:",error);
    });
}



/* =========================================================
   AUTH BUTTON
   ========================================================= */

function updateAuthButton(){
  const button = document.getElementById("loginBtn");
  if(!button) return;

  if(currentUser){
    button.textContent = "Account";
    button.onclick = function(){ openAccount(); };
  } else {
    button.textContent = "Sign in";
    button.onclick = function(){ openAuth(); };
  }
}


/* =========================================================
   AUTH MODAL
   ========================================================= */

function openAuth(message=""){
  if(currentUser){
    openAccount();
    return;
  }

  const content = document.getElementById("authContent");
  const modal = document.getElementById("authModal");
  if(!content || !modal) return;

  content.innerHTML = `
    <div class="auth-head">
      <span class="auth-icon">👤</span>
      <h2>ALLways Account</h2>
      <p class="muted">Sign in or create your customer account with email.</p>
    </div>
    ${message ? `<div class="auth-note">${escapeHtml(message)}</div>` : ""}
    <button class="googleBtn" id="googleSignInBtn">G&nbsp; Continue with Google</button>
    <div class="orLine"><span>or use email</span></div>
    <label>📧 Email<input id="authEmail" class="field" type="email" autocomplete="email" placeholder="you@example.com"></label>
    <label>🔒 Password<input id="authPassword" class="field" type="password" autocomplete="current-password" placeholder="At least 6 characters"></label>
    <button class="primary" id="loginSubmitBtn">Sign in</button>
    <button class="secondary" id="signupSubmitBtn">Create new account</button>
    <button class="textBtn" id="resetPasswordBtn">Forgot password?</button>
    <p id="authMsg" class="muted auth-msg"></p>
    <p class="policy">Your account is handled by Firebase Authentication. ALLways does not store your password in the Google Sheet.</p>
  `;

  const loginBtn = document.getElementById("loginSubmitBtn");
  const signupBtn = document.getElementById("signupSubmitBtn");
  const resetBtn = document.getElementById("resetPasswordBtn");
  const googleBtn = document.getElementById("googleSignInBtn");
  if(googleBtn) googleBtn.addEventListener("click", googleSignIn);
  if(loginBtn) loginBtn.addEventListener("click", loginCustomer);
  if(signupBtn) signupBtn.addEventListener("click", signupCustomer);
  if(resetBtn) resetBtn.addEventListener("click", resetPassword);

  modal.classList.remove("hidden");
}

function closeAuth(){
  const modal = document.getElementById("authModal");
  if(modal) modal.classList.add("hidden");
}

function authMessage(message){
  const element = document.getElementById("authMsg");
  if(element) element.textContent = message;
}


async function googleSignIn(){
  if(!firebaseReady){
    authMessage("Firebase is not connected. Please refresh the page and try again.");
    return;
  }
  authMessage("Opening Google sign-in…");
  try {
    const provider = new firebase.auth.GoogleAuthProvider();
    provider.setCustomParameters({prompt:"select_account"});
    await firebase.auth().signInWithPopup(provider);
    closeAuth();
  } catch(error) {
    console.error("ALLways Google sign-in error:", error);
    authMessage(authError(error));
  }
}


/* =========================================================
   SIGN IN
   ========================================================= */

async function loginCustomer(){
  if(!firebaseReady){
    authMessage("Firebase is not connected. Please refresh the page and try again.");
    return;
  }
  const emailElement = document.getElementById("authEmail");
  const passwordElement = document.getElementById("authPassword");
  if(!emailElement || !passwordElement) return;

  const email = emailElement.value.trim();
  const password = passwordElement.value;

  if(!email || !password){
    authMessage("Enter your email and password.");
    return;
  }

  authMessage("Signing in…");
  try {
    await firebase.auth().signInWithEmailAndPassword(email, password);
    closeAuth();
  } catch(error) {
    console.error("ALLways sign-in error:", error);
    authMessage(authError(error));
  }
}


/* =========================================================
   CREATE ACCOUNT
   ========================================================= */

async function signupCustomer(){
  if(!firebaseReady){
    authMessage("Firebase is not connected. Please refresh the page and try again.");
    return;
  }
  const emailElement = document.getElementById("authEmail");
  const passwordElement = document.getElementById("authPassword");
  if(!emailElement || !passwordElement) return;

  const email = emailElement.value.trim();
  const password = passwordElement.value;

  if(!email || !password){
    authMessage("Enter an email and password.");
    return;
  }
  if(password.length < 6){
    authMessage("Password must be at least 6 characters.");
    return;
  }

  authMessage("Creating your account…");
  try {
    await firebase.auth().createUserWithEmailAndPassword(email, password);
    closeAuth();
  } catch(error) {
    console.error("ALLways account creation error:", error);
    authMessage(authError(error));
  }
}


/* =========================================================
   PASSWORD RESET
   ========================================================= */

async function resetPassword(){
  if(!firebaseReady){
    authMessage("Firebase is not connected. Please refresh the page and try again.");
    return;
  }
  const emailElement = document.getElementById("authEmail");
  if(!emailElement) return;

  const email = emailElement.value.trim();
  if(!email){
    authMessage("Enter your email first.");
    return;
  }

  try {
    await firebase.auth().sendPasswordResetEmail(email);
    authMessage("Password reset email sent. Check your inbox.");
  } catch(error) {
    console.error("ALLways password reset error:", error);
    authMessage(authError(error));
  }
}


/* =========================================================
   CUSTOMER SUPPORT
   ========================================================= */
async function openSupport(prefill){
  if(!currentUser){ openAuth(); return; }
  const content=document.getElementById("authContent"), modal=document.getElementById("authModal");
  if(!content||!modal)return;
  const orderOptions=orders.map(function(o){return '<option value="'+escapeHtml(o.id||o.orderId||'')+'">#'+escapeHtml(o.id||o.orderId||'Order')+'</option>';}).join("");
  content.innerHTML='<div class="auth-head"><span class="auth-icon">?</span><h2>Customer Support</h2><p class="muted">Choose the issue type so ALLways can route it correctly.</p></div>'+
    '<label>Area<select id="supportArea" class="field"><option value="Order">Order</option><option value="Ride">Ride</option><option value="Account">Account</option><option value="General">General</option></select></label>'+
    '<label id="supportOrderWrap">Order<select id="supportOrder" class="field"><option value="">Select an order</option>'+orderOptions+'</select></label>'+
    '<label>Issue<select id="supportCategory" class="field"><option>Order problem</option><option>Missing item</option><option>Wrong item</option><option>Damaged item</option><option>Delivery delayed</option><option>Cancellation / refund</option><option>Delivery partner issue</option><option>Ride issue</option><option>Carrier issue</option><option>Account / login</option><option>Suggestion</option><option>General issue</option></select></label>'+
    '<label>Message<textarea id="supportMessage" class="field" rows="4" placeholder="Tell us what happened..."></textarea></label>'+
    '<button class="primary" id="submitSupportBtn">Create support request</button><p id="supportMsg" class="muted auth-msg"></p>';
  const area=document.getElementById("supportArea"), orderWrap=document.getElementById("supportOrderWrap");
  area.value=prefill&&prefill.area?prefill.area:"Order";
  orderWrap.style.display=area.value==="Order"?"block":"none";
  area.addEventListener("change",function(){orderWrap.style.display=area.value==="Order"?"block":"none";});
  document.getElementById("submitSupportBtn").addEventListener("click",async function(){
    const msg=document.getElementById("supportMessage").value.trim();
    const category=document.getElementById("supportCategory").value;
    const orderId=document.getElementById("supportOrder").value;
    const a=area.value;
    if(!msg){document.getElementById("supportMsg").textContent="Please describe the issue.";return;}
    const btn=this;btn.disabled=true;document.getElementById("supportMsg").textContent="Submitting...";
    try{
      const ride=(a==="Ride");
      await db.collection("supportTickets").add({
        requesterId:currentUser.uid,requesterRole:"customer",customerId:currentUser.uid,
        customerName:currentUser.displayName||currentUser.email||"Customer",queue:"Customer Support",
        area:a,category:category,subcategory:category,subject:category,
        message:msg,orderId:orderId||null,rideId:prefill&&prefill.rideId?prefill.rideId:null,
        priority:category.includes("safety")?"urgent":"normal",status:"open",
        createdAt:firebase.firestore.FieldValue.serverTimestamp(),updatedAt:firebase.firestore.FieldValue.serverTimestamp()
      });
      document.getElementById("supportMsg").textContent="Support request created. ALLways will review it.";
      setTimeout(closeAuth,700);
    }catch(e){btn.disabled=false;document.getElementById("supportMsg").textContent="Could not create the request. Please try again.";}
  });
  modal.classList.remove("hidden");
}

/* =========================================================
   ACCOUNT
   ========================================================= */

function openAccount(){
  if(!currentUser){
    openAuth();
    return;
  }
  const content = document.getElementById("authContent");
  const modal = document.getElementById("authModal");
  if(!content || !modal) return;

  content.innerHTML = `
    <div class="auth-head">
      <span class="auth-icon">✓</span>
      <h2>Your ALLways Account</h2>
      <p class="muted">${escapeHtml(currentUser.email)}</p>
    </div>
    <button class="primary" id="myOrdersBtn">📦 My Orders</button><button class="secondary" id="customerSupportBtn">🎧 Customer Support</button>
    <button class="secondary" id="favouritesBtn">❤️ Saved favourites (${favouriteIds.size})</button>
    <button class="secondary" id="addressesBtn">🏠 Saved addresses (${savedAddresses.length})</button>
    ${isAdmin() ? '<button class="secondary" id="adminDashboardBtn">🛠 Admin Dashboard</button>' : ''}
    <button class="secondary" id="signOutBtn">Sign out</button>
  `;

  const myOrdersBtn = document.getElementById("myOrdersBtn");\n  const customerSupportBtn = document.getElementById("customerSupportBtn");
  const favouritesBtn = document.getElementById("favouritesBtn");
  const addressesBtn = document.getElementById("addressesBtn");
  const adminDashboardBtn = document.getElementById("adminDashboardBtn");
  const signOutBtn = document.getElementById("signOutBtn");
  if(customerSupportBtn){customerSupportBtn.addEventListener("click",function(){openSupport();});}\n  if(myOrdersBtn){
    myOrdersBtn.addEventListener("click", function(){
      showSection("orders");
      closeAuth();
    });
  }
  if(favouritesBtn){favouritesBtn.addEventListener("click",function(){closeAuth();favouritesOnly=true;showSection("shop");renderProducts();});}
  if(addressesBtn){addressesBtn.addEventListener("click",function(){alert(savedAddresses.length?savedAddresses.map(function(a,i){return (i+1)+". "+a.name+" — "+a.address;}).join("\n"):"No saved addresses yet. Save one during checkout.");});}
  if(adminDashboardBtn){
    adminDashboardBtn.addEventListener("click", function(){ window.location.href = "admin.html"; });
  }
  if(signOutBtn){
    signOutBtn.addEventListener("click", signOutCustomer);
  }

  modal.classList.remove("hidden");
}


/* =========================================================
   SIGN OUT
   ========================================================= */

async function signOutCustomer(){
  try {
    if(firebaseReady){
      await firebase.auth().signOut();
    }
  } catch(error) {
    console.error("ALLways sign-out error:", error);
  }
  cart = {};
  updateCart();
  closeAuth();
  showSection("shop");
}


/* =========================================================
   FIREBASE ERROR MESSAGES
   ========================================================= */

function authError(error){
  const code = error && error.code ? error.code : "";
  const messages = {
    "auth/invalid-email": "Please enter a valid email address.",
    "auth/user-disabled": "This account has been disabled.",
    "auth/user-not-found": "No account exists with this email.",
    "auth/wrong-password": "Incorrect password.",
    "auth/invalid-credential": "Email or password is incorrect.",
    "auth/weak-password": "Password is too weak. Use at least 6 characters.",
    "auth/email-already-in-use": "An account with this email already exists. Please sign in.",
    "auth/operation-not-allowed": "Email/password login is not enabled in Firebase.",
    "auth/too-many-requests": "Too many attempts. Please wait and try again.",
    "auth/network-request-failed": "Network error. Check your internet connection.",
    "auth/internal-error": "Firebase returned an internal error. Please try again."
  };

  if(messages[code]){
    return messages[code];
  }
  console.error("Unknown Firebase error code:", code, error);
  return code ? `Firebase error: ${code}` : "Something went wrong. Please try again.";
}


/* =========================================================
   START APP
   ========================================================= */

function startALLways(){
  console.log("ALLways application starting...");

  document.querySelectorAll(".tab").forEach(function(tab){
    tab.onclick = function(){
      showSection(tab.dataset.section);
    };
  });

  const search = document.getElementById("search");
  if(search){
    search.addEventListener("input", function(){favouritesOnly=false;renderProducts();});
  }

  const checkoutBtn = document.getElementById("checkoutBtn");
  if(checkoutBtn){
    checkoutBtn.addEventListener("click", openCheckout);
  }

  updateCart();
  renderOrders();

  // Firebase is initialized before loading the catalog so Firestore is available.
  loadInventory();

  initAuth();
  loadInventory();
}


/* =========================================================
   DOM READY
   ========================================================= */

if(document.readyState === "loading"){
  document.addEventListener("DOMContentLoaded", startALLways);
} else {
  startALLways();
}
