/* ============================================================
   Shop Manager — shared app.js (all pages)
   Page-specific logic lives in an inline <script> on each page.
   Public helpers are exposed on window.SM.
   ============================================================ */
(function () {
  "use strict";

  /* ---------- Theme ---------- */
  var THEME_KEY = "sm-theme";

  function systemDark() {
    return (
      window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches
    );
  }
  function currentTheme() {
    var a = document.documentElement.getAttribute("data-theme");
    return a === "dark" || a === "light" ? a : systemDark() ? "dark" : "light";
  }
  function applyTheme(theme) {
    document.documentElement.setAttribute("data-theme", theme);
    refreshThemeIcons();
    document.dispatchEvent(
      new CustomEvent("sm:theme", { detail: { theme: theme } }),
    );
  }
  function refreshThemeIcons() {
    var dark = currentTheme() === "dark";
    document.querySelectorAll("[data-theme-toggle]").forEach(function (btn) {
      btn.querySelectorAll(".i-sun").forEach(function (el) {
        el.classList.toggle("is-hidden", !dark);
      });
      btn.querySelectorAll(".i-moon").forEach(function (el) {
        el.classList.toggle("is-hidden", dark);
      });
      btn.setAttribute(
        "aria-label",
        dark ? "Switch to light mode" : "Switch to dark mode",
      );
      btn.setAttribute("aria-pressed", String(dark));
    });
  }
  document.addEventListener("click", function (e) {
    var btn = e.target.closest("[data-theme-toggle]");
    if (!btn) return;
    var next = currentTheme() === "dark" ? "light" : "dark";
    try {
      localStorage.setItem(THEME_KEY, next);
    } catch (_) {}
    applyTheme(next);
  });
  var stored = null;
  try {
    stored = localStorage.getItem(THEME_KEY);
  } catch (_) {}
  if (stored === "light" || stored === "dark") applyTheme(stored);
  else
    refreshThemeIcons(); /* no explicit choice: CSS prefers-color-scheme rules drive the theme */
  /* ---------- Lucide icons ---------- */
  function renderIcons() {
    if (window.lucide && window.lucide.createIcons) window.lucide.createIcons();
  }
  document.addEventListener("DOMContentLoaded", renderIcons);

  /* ---------- Tiny DOM + format helpers ---------- */
  function qs(sel, root) {
    return (root || document).querySelector(sel);
  }
  function qsa(sel, root) {
    return Array.prototype.slice.call((root || document).querySelectorAll(sel));
  }

  var CURRENCY = "$"; // later overridden by Settings
  function setCurrency(c) {
    CURRENCY = c || "$";
  }
  function formatMoney(n) {
    var sign = n < 0 ? "-" : "";
    return (
      sign +
      CURRENCY +
      Math.abs(n).toLocaleString("en-US", {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
      })
    );
  }
  function formatDate(iso) {
    var d = new Date(iso);
    return isNaN(d)
      ? "—"
      : d.toLocaleDateString("en-US", {
          month: "short",
          day: "numeric",
          year: "numeric",
        });
  }
  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return {
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
      }[c];
    });
  }
  function debounce(fn, ms) {
    var t;
    return function () {
      var args = arguments,
        self = this;
      clearTimeout(t);
      t = setTimeout(function () {
        fn.apply(self, args);
      }, ms || 250);
    };
  }

  /* ---------- Button loading state ---------- */
  function setLoading(btn, on, loadingText) {
    if (!btn) return;
    if (on) {
      btn.dataset.labelHtml = btn.innerHTML;
      btn.classList.add("is-loading");
      btn.disabled = true;
      btn.innerHTML =
        '<span class="spinner" aria-hidden="true"></span>' +
        (loadingText || "Loading…");
    } else {
      btn.classList.remove("is-loading");
      btn.disabled = false;
      if (btn.dataset.labelHtml) btn.innerHTML = btn.dataset.labelHtml;
      delete btn.dataset.labelHtml;
      renderIcons();
    }
  }

  /* ---------- Field validation helpers ---------- */
  function setFieldError(input, message) {
    var field = input.closest(".field");
    if (!field) return;
    field.classList.add("has-error");
    input.setAttribute("aria-invalid", "true");
    var err = field.querySelector(".field-error");
    if (err) {
      err.textContent = message;
      err.hidden = false;
      if (err.id) input.setAttribute("aria-describedby", err.id);
    }
  }
  function clearFieldError(input) {
    var field = input.closest(".field");
    if (!field) return;
    field.classList.remove("has-error");
    input.removeAttribute("aria-invalid");
    var err = field.querySelector(".field-error");
    if (err) err.hidden = true;
  }

  /* ---------- Toast ---------- */
  var toastContainer = null;
  function ensureToastContainer() {
    if (!toastContainer) {
      toastContainer = document.createElement("div");
      toastContainer.className = "toast-container";
      toastContainer.setAttribute("aria-live", "polite");
      document.body.appendChild(toastContainer);
    }
    return toastContainer;
  }
  var TOAST_ICONS = {
    success: "check-circle-2",
    error: "alert-circle",
    info: "info",
  };
  function toast(message, type) {
    type = type || "success";
    var el = document.createElement("div");
    el.className = "toast toast--" + type;
    el.setAttribute("role", "status");
    el.innerHTML =
      '<i data-lucide="' +
      (TOAST_ICONS[type] || "info") +
      '"></i>' +
      '<span class="toast-msg">' +
      escapeHtml(message) +
      "</span>" +
      '<button type="button" class="toast-close" aria-label="Dismiss notification"><i data-lucide="x"></i></button>';
    ensureToastContainer().appendChild(el);
    renderIcons();
    var timer = setTimeout(dismiss, 3800);
    function dismiss() {
      clearTimeout(timer);
      el.classList.add("is-leaving");
      setTimeout(function () {
        el.remove();
      }, 180);
    }
    el.querySelector(".toast-close").addEventListener("click", dismiss);
  }

  /* ---------- Modal / drawer layers ---------- */
  var layerStack = [];
  var lastFocused = null;

  function focusables(el) {
    return qsa(
      'a[href], button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex="-1"])',
      el,
    ).filter(function (n) {
      return n.offsetParent !== null || n === document.activeElement;
    });
  }
  function openLayer(el) {
    if (!el) return;
    var overlay = el.closest(".overlay");
    if (!overlay) return;
    lastFocused = document.activeElement;
    overlay.hidden = false;
    requestAnimationFrame(function () {
      overlay.classList.add("is-open");
    });
    document.body.style.overflow = "hidden";
    layerStack.push({ el: el, overlay: overlay });
    var target = el.querySelector("[data-autofocus]") || focusables(el)[0];
    if (target) target.focus();
  }
  function closeLayer(el) {
    var entry =
      el &&
      layerStack.filter(function (l) {
        return l.el === el;
      })[0];
    if (!entry) {
      entry = layerStack[layerStack.length - 1];
      if (!entry) return;
    }
    layerStack = layerStack.filter(function (l) {
      return l !== entry;
    });
    entry.overlay.classList.remove("is-open");
    setTimeout(function () {
      entry.overlay.hidden = true;
    }, 180);
    if (layerStack.length === 0) document.body.style.overflow = "";
    if (lastFocused && lastFocused.focus) lastFocused.focus();
  }
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && layerStack.length) {
      e.preventDefault();
      closeLayer(layerStack[layerStack.length - 1].el);
    }
    if (e.key === "Tab" && layerStack.length) {
      var list = focusables(layerStack[layerStack.length - 1].overlay);
      if (!list.length) return;
      var first = list[0],
        last = list[list.length - 1];
      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault();
        first.focus();
      }
    }
  });
  // close buttons inside layers + click on the dark backdrop
  document.addEventListener("click", function (e) {
    var closer = e.target.closest("[data-layer-close]");
    if (closer) {
      closeLayer(closer.closest(".modal, .drawer"));
      return;
    }
    if (
      e.target.classList &&
      e.target.classList.contains("overlay") &&
      layerStack.length
    ) {
      var top = layerStack[layerStack.length - 1];
      if (
        e.target === top.overlay &&
        top.overlay.dataset.dismissable !== "false"
      )
        closeLayer(top.el);
    }
  });

  /* ---------- Public API ---------- */
  window.SM = {
    qs: qs,
    qsa: qsa,
    toast: toast,
    formatMoney: formatMoney,
    setCurrency: setCurrency,
    formatDate: formatDate,
    escapeHtml: escapeHtml,
    debounce: debounce,
    setLoading: setLoading,
    setFieldError: setFieldError,
    clearFieldError: clearFieldError,
    openModal: openLayer,
    closeModal: closeLayer,
    openDrawer: openLayer,
    closeDrawer: closeLayer,
    icons: renderIcons,
  };
})();
/* ============================================================
   APPEND TO app.js — shared password helpers
   (used by signup now; change-password in Settings later)
   ============================================================ */
(function () {
  "use strict";

  var STRENGTH_LABELS = ["", "Weak", "Fair", "Good", "Strong"];

  function scorePassword(v) {
    if (!v) return 0;
    var p = 0;
    if (v.length >= 8) p++;
    if (v.length >= 12) p++;
    if (/[a-z]/.test(v) && /[A-Z]/.test(v)) p++;
    if (/\d/.test(v)) p++;
    if (/[^A-Za-z0-9]/.test(v)) p++;
    if (p <= 1) return 1;
    if (p === 2) return 2;
    if (p === 3) return 3;
    return 4;
  }

  var DEFAULT_RULES = [
    {
      label: "At least 8 characters",
      test: function (v) {
        return v.length >= 8;
      },
    },
    {
      label: "Upper and lower case letters",
      test: function (v) {
        return /[a-z]/.test(v) && /[A-Z]/.test(v);
      },
    },
    {
      label: "At least one number",
      test: function (v) {
        return /\d/.test(v);
      },
    },
  ];

  /* meter: .strength with 4 <span> bars + .strength-label
     rules: <ul> that this helper fills with li.i-check / li.i-dot items */
  function bindPasswordStrength(input, meterEl, rulesEl, onChange) {
    var rules = DEFAULT_RULES,
      items = [];
    if (rulesEl) {
      rulesEl.innerHTML = "";
      rules.forEach(function (r) {
        var li = document.createElement("li");
        li.innerHTML =
          '<i data-lucide="check" class="i-check"></i>' +
          '<i data-lucide="minus" class="i-dot"></i><span></span>';
        li.querySelector("span").textContent = r.label;
        rulesEl.appendChild(li);
        items.push(li);
      });
      if (window.SM && SM.icons) SM.icons();
    }
    function update() {
      var v = input.value,
        level = scorePassword(v);
      if (meterEl) {
        meterEl.hidden = !v;
        if (v) meterEl.setAttribute("data-level", String(level));
        else meterEl.removeAttribute("data-level");
        var label = meterEl.querySelector(".strength-label");
        if (label) label.textContent = STRENGTH_LABELS[level];
      }
      items.forEach(function (li, i) {
        li.classList.toggle("is-met", rules[i].test(v));
      });
      if (onChange) onChange(v, level);
    }
    input.addEventListener("input", update);
    update();
    return { update: update, rules: rules, score: scorePassword };
  }

  function bindPasswordToggle(btn, input) {
    if (!btn || !input) return;
    btn.addEventListener("click", function () {
      var show = input.type === "password";
      input.type = show ? "text" : "password";
      var eye = btn.querySelector(".i-eye"),
        eyeOff = btn.querySelector(".i-eye-off");
      if (eye) eye.classList.toggle("is-hidden", show);
      if (eyeOff) eyeOff.classList.toggle("is-hidden", !show);
      btn.setAttribute("aria-pressed", String(show));
      btn.setAttribute("aria-label", show ? "Hide password" : "Show password");
    });
  }

  window.SM = window.SM || {};
  SM.scorePassword = scorePassword;
  SM.bindPasswordStrength = bindPasswordStrength;
  SM.bindPasswordToggle = bindPasswordToggle;
})();
/* ============================================================
   APPEND TO app.js
   A. Shared shell (sidebar drawer + active nav) — call SM.initShell() on every app page.
   B. Shared mock dataset (exact schema field names) — SM.MOCK.
   C. Helpers: SM.badge, SM.onTheme.
   ============================================================ */
(function () {
  "use strict";

  /* ---------- A. Shell ---------- */
  SM.initShell = function () {
    var nav = document.body.getAttribute("data-nav");
    if (nav) {
      SM.qsa(".nav-link").forEach(function (a) {
        a.classList.toggle("is-active", a.getAttribute("data-nav") === nav);
      });
    }
    var drawer = SM.qs("#sidebar"),
      overlay = SM.qs("#sidebar-overlay"),
      btn = SM.qs("#nav-toggle");
    if (!drawer || !btn) return;
    function set(open) {
      drawer.classList.toggle("is-open", open);
      if (overlay) overlay.classList.toggle("is-open", open);
      btn.setAttribute("aria-expanded", String(open));
    }
    btn.addEventListener("click", function () {
      var open = !drawer.classList.contains("is-open");
      set(open);
      if (open) {
        var first = drawer.querySelector(".nav-link");
        if (first) first.focus();
      }
    });
    if (overlay)
      overlay.addEventListener("click", function () {
        set(false);
        btn.focus();
      });
    drawer.addEventListener("click", function (e) {
      if (e.target.closest(".nav-link"))
        set(false); /* navigate + close on mobile */
    });
    document.addEventListener("keydown", function (e) {
      if (
        e.key === "Escape" &&
        drawer.classList.contains("is-open") &&
        !document.querySelector(".overlay.is-open")
      ) {
        set(false);
        btn.focus();
      }
    });
  };

  /* ---------- B. Mock dataset ---------- */
  function d(daysAgo, hour, min) {
    var t = new Date();
    t.setHours(hour || 10, min || 0, 0, 0);
    t.setDate(t.getDate() - daysAgo);
    return t.toISOString();
  }
  function sumItems(items) {
    return items.reduce(function (s, it) {
      return s + it.qty * it.unit_price;
    }, 0);
  }

  SM.MOCK = {
    shop: {
      name: "Northwind Supply Co.",
      currency: "$",
      tax_rate: 8.5,
      user: { name: "Maya Chen", role: "Manager", initials: "MC" },
    },

    products: [
      {
        sku: "SKU-1001",
        name: "Arabica coffee beans 1kg",
        category: "Coffee",
        cost: 12.5,
        price: 19.9,
        stock: 42,
        reorder_level: 15,
        active: true,
      },
      {
        sku: "SKU-1002",
        name: "Ceramic pour-over dripper",
        category: "Brew gear",
        cost: 8.2,
        price: 16.5,
        stock: 6,
        reorder_level: 10,
        active: true,
      },
      {
        sku: "SKU-1003",
        name: "Paper filters 100-pack",
        category: "Brew gear",
        cost: 2.1,
        price: 4.9,
        stock: 0,
        reorder_level: 25,
        active: true,
      },
      {
        sku: "SKU-1004",
        name: "Stainless thermos 500ml",
        category: "Accessories",
        cost: 9.0,
        price: 18.0,
        stock: 23,
        reorder_level: 8,
        active: true,
      },
      {
        sku: "SKU-1005",
        name: "Cold brew bottle 1L",
        category: "Brew gear",
        cost: 6.4,
        price: 13.5,
        stock: 18,
        reorder_level: 10,
        active: true,
      },
      {
        sku: "SKU-1006",
        name: "Cocoa powder 250g",
        category: "Pantry",
        cost: 3.3,
        price: 6.9,
        stock: 54,
        reorder_level: 20,
        active: true,
      },
      {
        sku: "SKU-1007",
        name: "Glass storage jar 750ml",
        category: "Accessories",
        cost: 4.1,
        price: 9.5,
        stock: 31,
        reorder_level: 12,
        active: true,
      },
      {
        sku: "SKU-1008",
        name: "Matcha whisk bamboo",
        category: "Tea",
        cost: 5.2,
        price: 11.0,
        stock: 9,
        reorder_level: 10,
        active: true,
      },
      {
        sku: "SKU-1009",
        name: "Green tea 100g",
        category: "Tea",
        cost: 4.0,
        price: 8.5,
        stock: 37,
        reorder_level: 12,
        active: true,
      },
      {
        sku: "SKU-1010",
        name: "Milk pitcher 350ml",
        category: "Barista",
        cost: 7.8,
        price: 15.9,
        stock: 14,
        reorder_level: 6,
        active: true,
      },
      {
        sku: "SKU-1011",
        name: "Tamper 58mm",
        category: "Barista",
        cost: 11.0,
        price: 22.0,
        stock: 11,
        reorder_level: 5,
        active: true,
      },
      {
        sku: "SKU-1012",
        name: "Chai concentrate 1L",
        category: "Pantry",
        cost: 5.5,
        price: 11.9,
        stock: 26,
        reorder_level: 10,
        active: false,
      },
    ],

    customers: [
      {
        name: "Café Aurora",
        email: "aurora@example.com",
        phone: "+1 555-0132",
        address: "18 Maple St, Portland, OR",
        notes: "Prefers Tuesday deliveries.",
      },
      {
        name: "Bean & Barrel",
        email: "beanbarrel@example.com",
        phone: "+1 555-0177",
        address: "42 Dock Rd, Tacoma, WA",
        notes: "Net 30 payment terms.",
      },
      {
        name: "Green Leaf Bistro",
        email: "greenleaf@example.com",
        phone: "+1 555-0142",
        address: "9 Olive Ave, Portland, OR",
        notes: "",
      },
      {
        name: "Harbor Coffee Co.",
        email: "harbor@example.com",
        phone: "+1 555-0198",
        address: "77 Pier Loop, Seattle, WA",
        notes: "Ask for Dana when delivering.",
      },
      {
        name: "Sweet Tooth Bakery",
        email: "sweet@example.com",
        phone: "+1 555-0165",
        address: "5 Sugar Ln, Beaverton, OR",
        notes: "",
      },
      {
        name: "Corner Espresso",
        email: "corner@example.com",
        phone: "+1 555-0129",
        address: "31 Market St, Eugene, OR",
        notes: "New customer, first order pending.",
      },
    ],

    suppliers: [
      {
        name: "Roasters United",
        email: "roasters@example.com",
        phone: "+1 555-0201",
        notes: "Monthly invoices.",
      },
      {
        name: "BrewGear GmbH",
        email: "eu@brewgear.example.com",
        phone: "+49 30 5550110",
        notes: "Ships from Berlin, 10-day lead time.",
      },
      {
        name: "Pacific Packaging",
        email: "pacific@example.com",
        phone: "+1 555-0233",
        notes: "",
      },
      {
        name: "Tea Leaf & Co",
        email: "tea@example.com",
        phone: "+1 555-0254",
        notes: "Minimum order $200.",
      },
    ],

    orders: [
      {
        number: "ORD-1042",
        customer: "Café Aurora",
        status: "completed",
        payment: "paid",
        created_at: d(0, 9, 40),
        items: [
          { product: "Arabica coffee beans 1kg", qty: 6, unit_price: 19.9 },
          { product: "Paper filters 100-pack", qty: 10, unit_price: 4.9 },
          { product: "Milk pitcher 350ml", qty: 2, unit_price: 15.9 },
        ],
      },
      {
        number: "ORD-1041",
        customer: "Green Leaf Bistro",
        status: "pending",
        payment: "partial",
        created_at: d(0, 8, 5),
        items: [
          { product: "Arabica coffee beans 1kg", qty: 12, unit_price: 19.9 },
          { product: "Cold brew bottle 1L", qty: 4, unit_price: 13.5 },
        ],
      },
      {
        number: "ORD-1040",
        customer: "Harbor Coffee Co.",
        status: "pending",
        payment: "unpaid",
        created_at: d(1, 15, 22),
        items: [
          { product: "Matcha whisk bamboo", qty: 8, unit_price: 11.0 },
          { product: "Green tea 100g", qty: 6, unit_price: 8.5 },
        ],
      },
      {
        number: "ORD-1039",
        customer: "Bean & Barrel",
        status: "completed",
        payment: "paid",
        created_at: d(2, 11, 5),
        items: [
          { product: "Stainless thermos 500ml", qty: 10, unit_price: 18.0 },
          { product: "Tamper 58mm", qty: 5, unit_price: 22.0 },
        ],
      },
      {
        number: "ORD-1038",
        customer: "Sweet Tooth Bakery",
        status: "completed",
        payment: "paid",
        created_at: d(4, 10, 12),
        items: [
          { product: "Cocoa powder 250g", qty: 20, unit_price: 6.9 },
          { product: "Chai concentrate 1L", qty: 8, unit_price: 11.9 },
        ],
      },
      {
        number: "ORD-1037",
        customer: "Café Aurora",
        status: "cancelled",
        payment: "unpaid",
        created_at: d(5, 16, 48),
        items: [
          { product: "Ceramic pour-over dripper", qty: 3, unit_price: 16.5 },
        ],
      },
      {
        number: "ORD-1036",
        customer: "Green Leaf Bistro",
        status: "completed",
        payment: "partial",
        created_at: d(8, 9, 30),
        items: [
          { product: "Arabica coffee beans 1kg", qty: 15, unit_price: 19.9 },
        ],
      },
      {
        number: "ORD-1035",
        customer: "Harbor Coffee Co.",
        status: "completed",
        payment: "paid",
        created_at: d(12, 14, 2),
        items: [
          { product: "Glass storage jar 750ml", qty: 9, unit_price: 9.5 },
          { product: "Milk pitcher 350ml", qty: 7, unit_price: 15.9 },
        ],
      },
      {
        number: "ORD-1034",
        customer: "Bean & Barrel",
        status: "completed",
        payment: "paid",
        created_at: d(21, 10, 45),
        items: [
          { product: "Paper filters 100-pack", qty: 24, unit_price: 4.9 },
          { product: "Stainless thermos 500ml", qty: 6, unit_price: 18.0 },
        ],
      },
      {
        number: "ORD-1033",
        customer: "Sweet Tooth Bakery",
        status: "completed",
        payment: "paid",
        created_at: d(27, 13, 20),
        items: [
          { product: "Cold brew bottle 1L", qty: 10, unit_price: 13.5 },
          { product: "Cocoa powder 250g", qty: 12, unit_price: 6.9 },
        ],
      },
    ].map(function (o) {
      o.total = sumItems(o.items);
      return o;
    }),

    purchase_orders: [
      {
        number: "PO-0231",
        supplier: "Roasters United",
        status: "received",
        created_at: d(12, 9, 0),
        items: [
          { product: "Arabica coffee beans 1kg", qty: 40, unit_cost: 12.5 },
        ],
      },
      {
        number: "PO-0232",
        supplier: "BrewGear GmbH",
        status: "received",
        created_at: d(6, 11, 30),
        items: [
          { product: "Ceramic pour-over dripper", qty: 30, unit_cost: 8.2 },
          { product: "Stainless thermos 500ml", qty: 20, unit_cost: 9.0 },
        ],
      },
      {
        number: "PO-0233",
        supplier: "Pacific Packaging",
        status: "ordered",
        created_at: d(2, 14, 10),
        items: [
          { product: "Paper filters 100-pack", qty: 200, unit_cost: 2.1 },
          { product: "Glass storage jar 750ml", qty: 30, unit_cost: 4.1 },
        ],
      },
      {
        number: "PO-0234",
        supplier: "Tea Leaf & Co",
        status: "ordered",
        created_at: d(1, 10, 15),
        items: [
          { product: "Matcha whisk bamboo", qty: 30, unit_cost: 5.2 },
          { product: "Green tea 100g", qty: 40, unit_cost: 4.0 },
        ],
      },
      {
        number: "PO-0230",
        supplier: "Roasters United",
        status: "cancelled",
        created_at: d(20, 9, 45),
        items: [{ product: "Cocoa powder 250g", qty: 20, unit_cost: 3.3 }],
      },
    ].map(function (p) {
      p.total = sumItems(p.items);
      return p;
    }),

    expenses: [
      {
        spent_on: d(1, 9, 0),
        category: "Rent",
        amount: 1200.0,
        notes: "Monthly rent",
      },
      {
        spent_on: d(2, 12, 0),
        category: "Utilities",
        amount: 84.2,
        notes: "Electricity + water",
      },
      {
        spent_on: d(3, 15, 0),
        category: "Packaging",
        amount: 156.9,
        notes: "Kraft bags and labels",
      },
      {
        spent_on: d(5, 10, 0),
        category: "Shipping",
        amount: 42.0,
        notes: "Courier surcharge",
      },
      {
        spent_on: d(8, 11, 0),
        category: "Marketing",
        amount: 120.0,
        notes: "Local ads",
      },
      {
        spent_on: d(12, 14, 0),
        category: "Repairs",
        amount: 210.0,
        notes: "Espresso machine service",
      },
      { spent_on: d(15, 9, 0), category: "Internet", amount: 59.0, notes: "" },
      {
        spent_on: d(18, 16, 0),
        category: "Cleaning",
        amount: 36.0,
        notes: "Monthly cleaning service",
      },
    ],

    stock_movements: [
      {
        product: "Arabica coffee beans 1kg",
        delta: -6,
        created_at: d(0, 9, 41),
        reason: "Sale ORD-1042",
        user: "Maya Chen",
      },
      {
        product: "Arabica coffee beans 1kg",
        delta: -12,
        created_at: d(0, 8, 6),
        reason: "Sale ORD-1041",
        user: "Maya Chen",
      },
      {
        product: "Paper filters 100-pack",
        delta: -8,
        created_at: d(2, 13, 0),
        reason: "Damaged in storage",
        user: "Maya Chen",
      },
      {
        product: "Ceramic pour-over dripper",
        delta: 30,
        created_at: d(6, 11, 45),
        reason: "Received PO-0232",
        user: "Maya Chen",
      },
      {
        product: "Stainless thermos 500ml",
        delta: 20,
        created_at: d(6, 11, 45),
        reason: "Received PO-0232",
        user: "Maya Chen",
      },
      {
        product: "Paper filters 100-pack",
        delta: -25,
        created_at: d(8, 9, 31),
        reason: "Sale ORD-1036",
        user: "Sam Ortiz",
      },
      {
        product: "Arabica coffee beans 1kg",
        delta: 40,
        created_at: d(12, 9, 20),
        reason: "Received PO-0231",
        user: "Maya Chen",
      },
      {
        product: "Matcha whisk bamboo",
        delta: -4,
        created_at: d(15, 10, 5),
        reason: "Sample for Café Aurora",
        user: "Sam Ortiz",
      },
    ],
  };

  /* ---------- C. Helpers ---------- */
  var BADGE_CLS = {
    pending: "badge-warning",
    completed: "badge-success",
    cancelled: "badge-danger",
    ordered: "badge-info",
    received: "badge-success",
    unpaid: "badge-danger",
    partial: "badge-warning",
    paid: "badge-success",
    active: "badge-success",
    inactive: "badge-neutral",
    low: "badge-warning",
    out: "badge-danger",
  };
  SM.badge = function (status, label) {
    var key = String(status).toLowerCase();
    var cls = BADGE_CLS[key] || "badge-neutral";
    var text = label || key.charAt(0).toUpperCase() + key.slice(1);
    return (
      '<span class="badge ' +
      cls +
      '"><span class="dot"></span>' +
      text +
      "</span>"
    );
  };
  SM.onTheme = function (fn) {
    document.addEventListener("sm:theme", function (e) {
      fn(e.detail ? e.detail.theme : null);
    });
  };
})();
/* ============================================================
   D. Date format — value comes from profiles.date_format (set by SM.loadContext)
   ============================================================ */
(function () {
  "use strict";
  var FMT = "mdy";
  function pad(n) {
    return ("0" + n).slice(-2);
  }
  function fmtDate(iso) {
    var d = new Date(iso);
    if (isNaN(d)) return "—";
    var m = d.toLocaleDateString("en-US", { month: "short" });
    var day = d.getDate(),
      y = d.getFullYear();
    if (FMT === "dmy") return day + " " + m + " " + y;
    if (FMT === "iso") return y + "-" + pad(d.getMonth() + 1) + "-" + pad(day);
    return m + " " + day + ", " + y;
  }
  SM.setDateFormat = function (f) {
    FMT = f || "mdy";
  };
  SM.formatDate = fmtDate;
})();
/* ============================================================
   APPEND TO app.js — E. Currency-aware chart tick formatter
   ============================================================ */
(function () {
  'use strict';
  SM.moneyTick = function (v) {
    var c = (SM.ctx && SM.ctx.shop && SM.ctx.shop.currency) || (SM.MOCK && SM.MOCK.shop.currency) || '$';
    return c + Number(v).toLocaleString('en-US');
  };
})();
/* ============================================================
   APPEND TO app.js — F. Shared initials helper
   ============================================================ */
(function () {
  'use strict';
  SM.initials = function (name) {
    return String(name || '').trim().split(/\s+/).slice(0, 2)
      .map(function (w) { return w.charAt(0); }).join('').toUpperCase() || '?';
  };
})();

/* ============================================================
   G. SUPABASE SHARED LAYER
   Load order on every page: supabase-js (pinned) -> config.js -> app.js
   Pages call:  await SM.requireAuth();  var ctx = await SM.loadContext();
   (login / signup / forgot-password must NOT call requireAuth)
   ============================================================ */
(function () {
  "use strict";

  /* ---------- client (one instance) ---------- */
  var cfg = window.SM_CONFIG || {};
  if (window.supabase && cfg.SUPABASE_URL && cfg.SUPABASE_ANON_KEY) {
    SM.db = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
    });
  } else {
    console.error("Supabase client not created: load supabase-js and config.js before app.js.");
  }

  /* ---------- error handling ---------- */
  SM.handleError = function (err) {
    var msg = (err && err.message) || "";
    var code = err && err.code ? String(err.code) : "";
    var status = err && err.status;
    var text;

    if (err && err.userMessage) {
      text = err.userMessage;
    } else if (!navigator.onLine || /failed to fetch|networkerror|load failed|network request failed/i.test(msg)) {
      text = "Network problem. Check your connection and try again.";
    } else if (code === "42501" || status === 401 || status === 403 || /row-level security|permission denied/i.test(msg)) {
      text = "You do not have access to do that.";
    } else if (/invalid login credentials/i.test(msg)) {
      text = "Incorrect email or password.";
    } else if (code === "user_already_exists" || /already registered/i.test(msg)) {
      text = "An account with this email already exists.";
    } else if (code === "weak_password" || /password should be|weak password/i.test(msg)) {
      text = "That password is too weak. Choose a stronger one.";
    } else if (status === 429 || /rate.?limit|too many requests/i.test(msg + " " + code)) {
      text = "Too many attempts. Please wait a moment and try again.";
    } else if (code === "23503") {
      text = "This item is linked to other records and cannot be removed.";
    } else if (code === "23505") {
      text = "That value already exists.";
    } else if (code === "P0001" && msg) {
      /* exceptions raised by our RPCs, e.g. "Not enough stock for ..." */
      text = msg;
    } else {
      text = "Something went wrong. Please try again.";
    }
    console.error(err);
    SM.toast(text, "error");
  };

  /* ---------- auth guard (app pages only) ---------- */
  var guardBound = false;
  SM.requireAuth = async function () {
    try {
      var res = await SM.db.auth.getSession(); /* refreshes an expired token when possible */
      var session = res.data && res.data.session;
      if (res.error || !session) {
        window.location.replace("login.html");
        return null;
      }
      if (!guardBound) {
        guardBound = true;
        SM.db.auth.onAuthStateChange(function (event, s) {
          if (event === "SIGNED_OUT" || !s) window.location.replace("login.html");
        });
      }
      return session;
    } catch (e) {
      window.location.replace("login.html");
      return null;
    }
  };

  /* ---------- context: profile + role + shop (cached) ---------- */
  var HIDDEN_FOR_STAFF = ["suppliers", "purchases", "expenses"]; /* data-nav values */

  function cap(s) {
    return s ? s.charAt(0).toUpperCase() + s.slice(1) : "";
  }
  function applyContext(ctx) {
    var shopEl = document.querySelector("[data-shop-name], .sidebar-footer-row > .text-3");
    if (shopEl) shopEl.textContent = ctx.shop.name;
    var nameEl = document.querySelector("[data-user-name], .user-meta .user-name");
    if (nameEl) nameEl.textContent = ctx.profile.full_name;
    var avEl = document.querySelector("[data-user-initials], .user-row .avatar");
    if (avEl) avEl.textContent = SM.initials(ctx.profile.full_name);
    var roleEl = document.querySelector("[data-user-role], .user-meta .user-role");
    if (roleEl) roleEl.textContent = cap(ctx.role);

    if (ctx.role === "staff") {
      SM.qsa(".nav-link").forEach(function (a) {
        if (HIDDEN_FOR_STAFF.indexOf(a.getAttribute("data-nav")) === -1) return;
        a.style.display = "none";
        if (a.parentElement && a.parentElement.tagName === "LI") a.parentElement.style.display = "none";
      });
    }
  }

  var ctxPromise = null;
  SM.loadContext = function (force) {
    if (ctxPromise && !force) return ctxPromise;
    ctxPromise = (async function () {
      var u = await SM.db.auth.getUser();
      var user = u.data && u.data.user;
      if (u.error || !user) throw u.error || new Error("No session");

      var r = await Promise.all([
        SM.db.from("profiles").select("id,email,full_name,date_format").eq("id", user.id).maybeSingle(),
        SM.db.from("shop_members").select("shop_id,role").eq("user_id", user.id).maybeSingle(),
      ]);
      if (r[0].error) throw r[0].error;
      if (r[1].error) throw r[1].error;
      if (!r[0].data || !r[1].data) {
        var e = new Error("No shop for this user");
        e.userMessage = "Your account is not linked to a shop yet.";
        throw e;
      }

      var shopRes = await SM.db
        .from("shops")
        .select("id,name,currency,tax_rate,low_stock_threshold,timezone,address,logo_path")
        .eq("id", r[1].data.shop_id)
        .single();
      if (shopRes.error) throw shopRes.error;

      var ctx = { user: user, profile: r[0].data, member: r[1].data, role: r[1].data.role, shop: shopRes.data };
      SM.ctx = ctx;
      SM.setCurrency(ctx.shop.currency);
      SM.setDateFormat(ctx.profile.date_format);

      /* transitional: pages not yet converted still read SM.MOCK.shop */
      if (SM.MOCK && SM.MOCK.shop) {
        SM.MOCK.shop.name = ctx.shop.name;
        SM.MOCK.shop.currency = ctx.shop.currency;
        SM.MOCK.shop.tax_rate = Number(ctx.shop.tax_rate);
      }

      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", function () { applyContext(ctx); });
      } else {
        applyContext(ctx);
      }
      return ctx;
    })().catch(function (e) {
      ctxPromise = null;
      throw e;
    });
    return ctxPromise;
  };

  /* role helpers — UX only, RLS is the real protection */
  SM.isManager = function () { return !!SM.ctx && (SM.ctx.role === "owner" || SM.ctx.role === "manager"); };
  SM.isOwner = function () { return !!SM.ctx && SM.ctx.role === "owner"; };
})();
