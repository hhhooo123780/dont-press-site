/*
 * Public browser settings only. Never put a Supabase service_role key,
 * database password, or any other secret in this file.
 */
window.SITE_CONFIG = {
  supabaseUrl: "",       // e.g. https://YOUR_PROJECT_REF.supabase.co
  supabaseAnonKey: "",   // Supabase publishable / anon key; secure access with the SQL RLS policies
  dailyGoal: 5000,
  affiliateLinks: [
    // { title: "商品名", description: "説明", url: "https://..." }
  ],
  displayAdScriptUrl: "", // Official ad provider script URL only; use the provider's tag documentation.
  displayAdSlotId: "",
  sponsorVideoUrl: ""     // HTTPS MP4/WebM, 5–15 seconds, with permission to use.
};
