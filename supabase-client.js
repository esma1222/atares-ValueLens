// Supabase browser client for the WTT Value Simulator passcode gate.
//
// The passcode is NOT stored in this file or anywhere in the client bundle.
// Verification is delegated to the `verify_passcode` Postgres RPC, which
// compares the entered code against a bcrypt hash held in a locked-down table
// (see supabase/migrations). The publishable key below is safe to ship in the
// browser — it grants only what row-level security allows, and the access-code
// table is readable by no one.
(function () {
  "use strict";

  var SUPABASE_URL = "https://oldfpsvbmwhkbtfrzmdi.supabase.co";
  var SUPABASE_PUBLISHABLE_KEY = "sb_publishable_ZJ1eHnFmU25TZ__oQSYjWA_6CkM5LXU";

  function getClient() {
    if (window.__wttSupabase) return window.__wttSupabase;
    if (!window.supabase || !window.supabase.createClient) return null;
    window.__wttSupabase = window.supabase.createClient(
      SUPABASE_URL,
      SUPABASE_PUBLISHABLE_KEY,
      { auth: { persistSession: false, autoRefreshToken: false } }
    );
    return window.__wttSupabase;
  }

  window.WTTAuth = {
    // Resolves true for a correct passcode, false for a wrong one.
    // Throws if Supabase is unreachable or the RPC errors, so the caller can
    // show a "connection unavailable" message distinct from a wrong passcode.
    verifyPasscode: function (code) {
      var client = getClient();
      if (!client) return Promise.reject(new Error("supabase-unavailable"));
      return client
        .rpc("verify_passcode", { candidate: (code || "").trim() })
        .then(function (res) {
          if (res.error) throw res.error;
          return res.data === true;
        });
    }
  };
})();
