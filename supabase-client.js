// Supabase browser client for atares ValueLens.
//
// Exposes window.WTTAuth with three groups of calls:
//   verifyPasscode()                  — admin gate
//   captureLead()                     — sign-in lead capture (write-only)
//   listProjects/saveProject/deleteProject — admin scenario library
//
// No secret lives in this file. The admin passcode is verified server-side by
// the `verify_passcode` RPC, and every privileged project call re-presents the
// passcode for the database to check (the app has no Supabase Auth session).
// The publishable key below is designed to be public: it can only do what RLS
// and the granted RPCs allow, and neither `access_codes`, `leads` nor
// `projects` is readable through it directly.
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

  function norm(code) {
    return (code || "").trim().toLowerCase();
  }

  // Runs an RPC and rejects with the underlying error, logging it so a missing
  // migration (PGRST202) is distinguishable from a genuine negative result.
  function call(fn, params) {
    var client = getClient();
    if (!client) {
      console.error("[WTTAuth] supabase-js did not load (CDN blocked?)");
      return Promise.reject(new Error("supabase-unavailable"));
    }
    return client.rpc(fn, params).then(function (res) {
      if (res.error) {
        console.error("[WTTAuth] " + fn + " failed:", res.error);
        throw res.error;
      }
      return res.data;
    });
  }

  window.WTTAuth = {
    // ---- admin gate ------------------------------------------------------
    // true = correct passcode, false = wrong. Rejects if Supabase is
    // unreachable, so callers can distinguish that from a wrong code.
    verifyPasscode: function (code) {
      return call("verify_passcode", { candidate: norm(code) }).then(function (d) {
        return d === true;
      });
    },

    // ---- lead capture ----------------------------------------------------
    // Write-only. Callers should treat failure as non-fatal: a visitor must
    // never be blocked from using the tool because capture failed.
    captureLead: function (lead) {
      return call("capture_lead", {
        p_name: lead.name,
        p_email: lead.email,
        p_company: lead.company || null,
        p_lang: lead.lang || null,
        // TechSpheres newsletter fields (salutation / first / last / consent)
        p_salutation: lead.salutation || null,
        p_first_name: lead.first || null,
        p_last_name: lead.last || null,
        p_newsletter_consent: lead.consent === true
      });
    },

    // ---- admin scenario library -----------------------------------------
    // Resolves to a { name: {name, savedAt, data} } map matching the shape the
    // app already keeps in localStorage.
    listProjects: function (code) {
      return call("list_projects", { passcode: norm(code) }).then(function (rows) {
        var out = {};
        (rows || []).forEach(function (r) {
          out[r.name] = {
            name: r.name,
            savedAt: new Date(r.saved_at).getTime(),
            data: r.data
          };
        });
        return out;
      });
    },

    saveProject: function (code, name, data) {
      return call("save_project", {
        passcode: norm(code),
        p_name: name,
        p_data: data
      });
    },

    deleteProject: function (code, name) {
      return call("delete_project", { passcode: norm(code), p_name: name });
    }
  };
})();
