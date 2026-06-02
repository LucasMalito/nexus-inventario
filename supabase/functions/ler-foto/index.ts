// Lê a foto de uma contagem com Gemini 2.5 Flash:
//  - balanca_foto: lê o PESO no visor (em gramas) + descreve o que vê
//  - nivel_foto:   estima o NÍVEL da garrafa (0-100%) + descreve
// A chave do Gemini fica como segredo (GEMINI_API_KEY), nunca exposta no app.

const GEMINI_KEY = Deno.env.get("GEMINI_API_KEY") ?? "";
const MODEL = "gemini-2.5-flash";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(o: unknown, status = 200) {
  return new Response(JSON.stringify(o), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

function toBase64(bytes: Uint8Array): string {
  let bin = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(bin);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (!GEMINI_KEY) return json({ erro: "GEMINI_API_KEY nao configurada" }, 500);

  try {
    const { fotoUrl, tipo } = await req.json();
    if (!fotoUrl) return json({ erro: "fotoUrl faltando" }, 400);

    // baixa a imagem do Storage
    const imgRes = await fetch(fotoUrl);
    if (!imgRes.ok) return json({ erro: "nao consegui baixar a foto" }, 400);
    const bytes = new Uint8Array(await imgRes.arrayBuffer());
    const b64 = toBase64(bytes);
    const mime = imgRes.headers.get("content-type") || "image/jpeg";

    const prompt = tipo === "nivel_foto"
      ? `Esta é a foto de uma garrafa de bebida. Estime quanto de líquido resta dentro dela, em porcentagem (0 = vazia, 100 = cheia). Descreva em 2 a 4 palavras o que você vê (ex: "garrafa de whisky"). Responda SÓ em JSON: {"legivel": boolean, "valor": number, "unidade": "%", "descricao": string}. Use legivel=false se a foto não permitir estimar.`
      : `Esta é a foto do VISOR de uma balança digital. Leia APENAS o número que aparece no visor (o peso). Se o visor estiver em kg, converta para GRAMAS. Descreva em 2 a 4 palavras o que está sendo pesado (ex: "carne vermelha", "garrafas de whisky"). Responda SÓ em JSON: {"legivel": boolean, "valor": number, "unidade": "g", "descricao": string}. Use legivel=false se não der pra ler o número do visor com clareza.`;

    const body = {
      contents: [{
        parts: [
          { text: prompt },
          { inline_data: { mime_type: mime, data: b64 } },
        ],
      }],
      generationConfig: { responseMimeType: "application/json", temperature: 0 },
    };

    const r = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${GEMINI_KEY}`,
      { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) },
    );
    const data = await r.json();
    if (!r.ok) return json({ erro: "gemini", detalhe: data }, 500);

    const txt = data?.candidates?.[0]?.content?.parts?.[0]?.text ?? "{}";
    let parsed: Record<string, unknown>;
    try { parsed = JSON.parse(txt); } catch { parsed = { legivel: false, descricao: "resposta nao-JSON", raw: txt }; }
    return json(parsed);
  } catch (e) {
    return json({ erro: String(e) }, 500);
  }
});
