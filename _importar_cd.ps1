# ============================================================
# Importa o catálogo de itens do CD pro inv_itens (Supabase)
# Fontes: relatórios do Everest exportados em CSV (ANSI)
#   1) Itens (Produtos)*.csv  -> intermediários PRODUZIDOS no CD
#   2) Compras no Período*.csv -> matérias-primas / insumos COMPRADOS
# Uso:  powershell -File _importar_cd.ps1
# ============================================================

$ErrorActionPreference = 'Stop'

$SB   = 'https://kuyhkltbwlkvtgbabscv.supabase.co'
$KEY  = 'sb_publishable_dW-JZ00n74dSLCrznBJ6gw_K8AE1VIq'
$CD   = '34ca79e9-eed8-4a74-b2ec-e396bf87bdf2'   # inv_casas: Centro de Distribuição

$desktop = (Get-Item "C:\Users\Lucas Malito\OneDrive\?rea de Trabalho").FullName
$csvProd    = Get-ChildItem -LiteralPath $desktop -Filter 'Itens (Produtos)*.csv'    | Select-Object -First 1
$csvCompras = Get-ChildItem -LiteralPath $desktop -Filter 'Compras*.csv'             | Select-Object -First 1
if (-not $csvProd -or -not $csvCompras) { throw 'CSV nao encontrado no Desktop.' }

function Limpa([string]$s) { return ($s -replace '\s+', ' ').Trim() }
function Num([string]$s) { if ([string]::IsNullOrWhiteSpace($s)) { return 0 } ; return [double]($s.Replace('.','').Replace(',','.')) }

$itens = @()

# ---------- 1) PRODUZIDOS no CD (intermediários) ----------
$prod = Import-Csv -LiteralPath $csvProd.FullName -Encoding Default | Where-Object { $_.'Situação' -eq 'ATIVO' }
foreach ($p in $prod) {
  $um = $p.UM
  $itens += [pscustomobject]@{
    casa_id           = $CD
    everest_id        = $p.Item
    nome              = Limpa $p.'Descrição do Item'
    categoria         = 'producao_cd'
    setor             = 'cd'
    metodo_contagem   = $(if ($um -eq 'KG') { 'balanca_foto' } else { 'unidades_foto' })
    unidade_medida    = $(if ($um -eq 'KG') { 'kg' } else { 'un' })
    valor_unitario_rs = 0
    risco             = 'medio'
  }
}
$nProd = $itens.Count
Write-Host "Produzidos no CD (intermediarios): $nProd"

# ---------- 2) COMPRADOS (matéria-prima / insumos) ----------
$tiposOk   = @('MATERIA PRIMA','PRODUTO ACABADO','MERCADORIA PARA REVENDA','EMBALAGEM')
$usoOk     = @('DESCARTAVEIS','MATERIAL DE LIMPEZA E HIGIENE','ETIQUETAS E BOBINAS')
$riscoAlto = @('VINHOS','LICORES','ESPUMANTE','VODKA','GIN','CACHACA','APERITIVO','PROTEINA','XAROPE')

$compras = Import-Csv -LiteralPath $csvCompras.FullName -Encoding Default | Where-Object {
  ($tiposOk -contains $_.'Tipo Item') -or
  ($_.'Tipo Item' -eq 'MATERIAL DE USO E CONSUMO' -and ($usoOk -contains $_.'Grupo'))
}

$grupos = $compras | Group-Object 'Item'
$nComp = 0
foreach ($g in $grupos) {
  # linha mais recente do item (pra pegar o último preço pago)
  $ult = $g.Group | Sort-Object { [datetime]::ParseExact($_.'D. Lançamento','dd/MM/yyyy',$null) } | Select-Object -Last 1
  $um  = $ult.'UM Padrão De Estoque'
  $gg  = $ult.'Grande Grupo'

  $cat = 'insumo_cozinha'
  if ($gg -eq 'BEBIDAS') { $cat = 'bebida_fechada' }
  elseif ($gg -eq 'PRODUTO DE CARDAPIO') { $cat = 'revenda' }
  elseif ($ult.'Tipo Item' -eq 'MERCADORIA PARA REVENDA') { $cat = 'revenda' }
  elseif ($gg -in @('USO E CONSUMO','EMBALAGENS','HIGIENE E LIMPEZA')) { $cat = 'uso_consumo' }

  $itens += [pscustomobject]@{
    casa_id           = $CD
    everest_id        = $ult.Item
    nome              = Limpa $ult.'Descrição Item'
    categoria         = $cat
    setor             = 'cd'
    metodo_contagem   = $(if ($um -eq 'KG') { 'balanca_foto' } else { 'unidades_foto' })
    unidade_medida    = $(if ($um -eq 'KG') { 'kg' } else { 'un' })
    valor_unitario_rs = Num $ult.'V. Unitário Convertido'
    risco             = $(if ($riscoAlto -contains $ult.'Grupo') { 'alto' } else { 'medio' })
  }
  $nComp++
}
Write-Host "Comprados (materia-prima/insumos): $nComp"
Write-Host ("TOTAL a subir: " + $itens.Count)

# ---------- evita duplicar: pega everest_id ja cadastrados no CD ----------
$h = @{ apikey = $KEY; Authorization = "Bearer $KEY" }
$existentes = Invoke-RestMethod -Uri "$SB/rest/v1/inv_itens?casa_id=eq.$CD&select=everest_id" -Headers $h
$jaTem = @{}
foreach ($e in $existentes) { if ($e.everest_id) { $jaTem[$e.everest_id] = $true } }
$novos = @($itens | Where-Object { -not $jaTem.ContainsKey($_.everest_id) })
Write-Host ("Ja cadastrados (pulando): " + ($itens.Count - $novos.Count) + " | Novos: " + $novos.Count)

# ---------- sobe em lotes de 200 ----------
$hPost = @{ apikey = $KEY; Authorization = "Bearer $KEY"; 'Content-Type' = 'application/json'; Prefer = 'return=minimal' }
for ($i = 0; $i -lt $novos.Count; $i += 200) {
  $fim = [Math]::Min($i + 199, $novos.Count - 1)
  $lote = @($novos[$i..$fim])
  $json = ConvertTo-Json -InputObject $lote -Depth 3
  Invoke-RestMethod -Method Post -Uri "$SB/rest/v1/inv_itens" -Headers $hPost -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
  Write-Host ("  lote " + ($i/200 + 1) + " ok (" + $lote.Count + " itens)")
}
Write-Host 'PRONTO! Catalogo do CD no ar.'
