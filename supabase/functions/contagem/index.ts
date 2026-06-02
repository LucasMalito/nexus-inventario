// Serve o app de contagem (HTML guardado no Storage) com Content-Type correto.
// O Storage público força text/plain em HTML; esta função re-serve como text/html.
const APP_URL =
  "https://kuyhkltbwlkvtgbabscv.supabase.co/storage/v1/object/public/inventario/app/contagem.html";

Deno.serve(async () => {
  try {
    const r = await fetch(APP_URL, { cache: "no-store" });
    const html = await r.text();
    return new Response(html, {
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
      },
    });
  } catch (e) {
    return new Response("Erro ao carregar o app: " + e, { status: 500 });
  }
});
