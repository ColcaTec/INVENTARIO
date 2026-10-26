import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const allowedOrigins = new Set(["https://colcatec.github.io", "http://localhost:4173", "http://localhost:5500"]);
function corsHeaders(origin: string | null) {
  const allowed = origin && allowedOrigins.has(origin) ? origin : "https://colcatec.github.io";
  return {
    "Access-Control-Allow-Origin": allowed,
    "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}
function json(data: unknown, status: number, origin: string | null) {
  return new Response(JSON.stringify(data), { status, headers: { ...corsHeaders(origin), "Content-Type": "application/json" } });
}
function base64url(value: string | Uint8Array) {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
async function googleAccessToken(serviceAccount: { client_email?: string; private_key?: string }) {
  if (!serviceAccount.client_email || !serviceAccount.private_key) throw new Error("La cuenta de servicio de Google no tiene los campos requeridos.");
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(JSON.stringify({
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/cloud-platform",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const signingInput = header + "." + claims;
  const pem = serviceAccount.private_key.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const keyBytes = Uint8Array.from(atob(pem), c => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", keyBytes.buffer, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(signingInput)));
  const assertion = signingInput + "." + base64url(signature);
  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!tokenResponse.ok) throw new Error("No se pudo autenticar con Google Cloud.");
  const tokenData = await tokenResponse.json();
  if (!tokenData.access_token) throw new Error("Google Cloud no entregó un token de acceso.");
  return tokenData.access_token as string;
}
function entityValue(entities: Array<Record<string, unknown>>, type: string) {
  const entity = entities.find(item => item.type === type);
  if (!entity) return { value: "", confidence: 0 };
  const normalized = entity.normalizedValue as Record<string, unknown> | undefined;
  return {
    value: String(normalized?.text || entity.mentionText || "").trim(),
    confidence: Number(entity.confidence || 0),
  };
}
Deno.serve(async (request: Request) => {
  const origin = request.headers.get("origin");
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(origin) });
  if (request.method !== "POST") return json({ ok: false, error: "Método no permitido." }, 405, origin);

  try {
    const authorization = request.headers.get("Authorization") || "";
    if (!authorization.toLowerCase().startsWith("bearer ")) return json({ ok: false, error: "Inicia sesión para usar el OCR." }, 401, origin);
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") || "";
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: authorization } },
    });
    const { data: userData, error: userError } = await supabase.auth.getUser();
    if (userError || !userData.user) return json({ ok: false, error: "Tu sesión venció. Vuelve a ingresar a la app." }, 401, origin);
    const { data: profile, error: profileError } = await supabase.from("profiles").select("active").eq("id", userData.user.id).maybeSingle();
    if (profileError || !profile?.active) return json({ ok: false, error: "Tu usuario no está activo para usar la aplicación." }, 403, origin);

    const projectId = Deno.env.get("DOC_AI_PROJECT_ID") || "";
    const location = Deno.env.get("DOC_AI_LOCATION") || "";
    const processorId = Deno.env.get("DOC_AI_PROCESSOR_ID") || "";
    const serviceAccountJson = Deno.env.get("GOOGLE_SERVICE_ACCOUNT_JSON") || "";
    if (!projectId || !location || !processorId || !serviceAccountJson) {
      return json({ ok: false, error: "Document AI aún no está configurado en Supabase." }, 503, origin);
    }
    const body = await request.json();
    const imageBase64 = String(body.imageBase64 || "");
    const mimeType = String(body.mimeType || "");
    if (mimeType !== "image/jpeg" || !/^[A-Za-z0-9+/]+={0,2}$/.test(imageBase64) || imageBase64.length > 8_000_000) {
      return json({ ok: false, error: "La imagen preparada no es válida o es demasiado grande." }, 400, origin);
    }
    const serviceAccount = JSON.parse(serviceAccountJson);
    const accessToken = await googleAccessToken(serviceAccount);
    const endpoint = "https://" + location + "-documentai.googleapis.com/v1/projects/" + encodeURIComponent(projectId) +
      "/locations/" + encodeURIComponent(location) + "/processors/" + encodeURIComponent(processorId) + ":process";
    const googleResponse = await fetch(endpoint, {
      method: "POST",
      headers: { "Authorization": "Bearer " + accessToken, "Content-Type": "application/json" },
      body: JSON.stringify({ rawDocument: { content: imageBase64, mimeType } }),
    });
    if (!googleResponse.ok) {
      console.error("Document AI request failed with status", googleResponse.status);
      return json({ ok: false, error: "Google Document AI no pudo procesar la boleta. Verifica el procesador y sus permisos." }, 502, origin);
    }
    const result = await googleResponse.json();
    const document = result.document || {};
    const entities = Array.isArray(document.entities) ? document.entities as Array<Record<string, unknown>> : [];
    const supplier = entityValue(entities, "supplier_name");
    const documentNumber = entityValue(entities, "invoice_id");
    return json({
      ok: true,
      text: String(document.text || ""),
      supplierName: supplier.value,
      supplierConfidence: supplier.confidence,
      documentNumber: documentNumber.value,
      documentNumberConfidence: documentNumber.confidence,
    }, 200, origin);
  } catch (error) {
    console.error("receipt-ocr failed", error instanceof Error ? error.message : "unknown error");
    return json({ ok: false, error: "Falló el análisis de la boleta. Puedes completar los datos manualmente." }, 500, origin);
  }
});
