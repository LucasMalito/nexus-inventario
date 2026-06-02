-- =====================================================================
-- NEXUS INVENTÁRIO — Módulo de contagem anti-fraude (Botequim)
-- Sistema INTERNO  ->  ao criar, clicar em "Run without RLS"
-- Cole numa ABA NOVA do SQL Editor (+ New query)
-- =====================================================================

-- 1) CASAS (unidades: SP, SCS, AS, SBC, CD)
create table if not exists inv_casas (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  apelido     text,
  ativo       boolean not null default true,
  criada_em   timestamptz not null default now()
);

-- 2) FUNCIONÁRIOS (quem conta / gerentes)
create table if not exists inv_funcionarios (
  id          uuid primary key default gen_random_uuid(),
  casa_id     uuid references inv_casas(id),
  nome        text not null,
  whatsapp    text,                               -- pro alerta/auditoria
  papel       text not null default 'contador',   -- contador | gerente
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now()
);

-- 3) ITENS (catálogo, sincronizado do Everest)
create table if not exists inv_itens (
  id                 uuid primary key default gen_random_uuid(),
  casa_id            uuid references inv_casas(id),
  everest_id         text,                  -- id do item no Everest
  nome               text not null,
  categoria          text not null,         -- bebida_fechada | bebida_aberta | destilado_caro | insumo_cozinha | cd_caixa
  setor              text,                  -- bar, cozinha, adega, cd...
  metodo_contagem    text not null,         -- bip | balanca_foto | nivel_foto | master_foto
  codigo_barras      text,                  -- EAN da unidade (pro bip)
  codigo_master      text,                  -- EAN-14 da caixa fechada (CD)
  unidades_por_caixa int default 1,         -- quantas unidades a caixa-master tem
  tara_garrafa_g     numeric,               -- destilado: peso da garrafa vazia
  peso_cheio_g       numeric,               -- destilado: peso cheio (calcular ml)
  volume_ml          numeric,               -- destilado: volume nominal
  unidade_medida     text default 'un',     -- un | g | kg | ml
  valor_unitario_rs  numeric default 0,     -- pra calcular R$ de perda
  risco              text not null default 'medio', -- alto | medio | baixo
  ativo              boolean not null default true,
  atualizado_em      timestamptz not null default now()
);

-- 4) ESPERADO (snapshot do Everest: quanto DEVERIA ter) — base da contagem cega
create table if not exists inv_esperado (
  id                uuid primary key default gen_random_uuid(),
  casa_id           uuid references inv_casas(id),
  item_id           uuid references inv_itens(id),
  data_ref          date not null,
  estoque_inicial   numeric default 0,
  compras           numeric default 0,
  vendas            numeric default 0,
  estoque_esperado  numeric not null,       -- inicial + compras - vendas
  fonte             text default 'everest_api',
  sincronizado_em   timestamptz not null default now(),
  unique (casa_id, item_id, data_ref)
);

-- 5) CONTAGENS (cabeçalho — uma sessão de contagem de um setor)
create table if not exists inv_contagens (
  id                 uuid primary key default gen_random_uuid(),
  casa_id            uuid references inv_casas(id),
  funcionario_id     uuid references inv_funcionarios(id),
  setor              text,
  tipo               text not null default 'diaria',  -- diaria | recontagem | auditoria | dupla_cega
  status             text not null default 'aberta',  -- aberta | enviada | travada
  origem_contagem_id uuid references inv_contagens(id), -- se recontagem, aponta a original
  gps_lat            numeric,
  gps_lng            numeric,
  criada_em          timestamptz not null default now(),
  enviada_em         timestamptz                       -- ao enviar, trava (status=travada)
);

-- 6) CONTAGEM_ITENS (as linhas — o que foi contado, SEM ver o esperado)
create table if not exists inv_contagem_itens (
  id            uuid primary key default gen_random_uuid(),
  contagem_id   uuid references inv_contagens(id) on delete cascade,
  item_id       uuid references inv_itens(id),
  contado_via   text not null,            -- bip | balanca_foto | nivel_foto | master_foto
  bips          int default 0,            -- nº de bips (= unidades) quando for bip
  quantidade    numeric,                  -- quantidade final na unidade do item
  peso_g        numeric,                  -- cozinha/destilado
  nivel_pct     numeric,                  -- garrafa aberta (0-100%)
  foto_url      text,                     -- PROVA obrigatória (foto do item/visor/garrafa)
  ia_conferiu   boolean default false,    -- IA leu a foto e bateu?
  ia_valor_lido numeric,                  -- o que a IA leu (qtd/peso/nível)
  ia_divergiu   boolean default false,    -- IA != funcionário?
  criado_em     timestamptz not null default now()
);

-- 7) VARIÂNCIAS (cruzamento contado x esperado — o coração)
create table if not exists inv_variancias (
  id               uuid primary key default gen_random_uuid(),
  casa_id          uuid references inv_casas(id),
  item_id          uuid references inv_itens(id),
  contagem_item_id uuid references inv_contagem_itens(id),
  data_ref         date not null,
  esperado         numeric not null,
  contado          numeric not null,
  diferenca        numeric not null,       -- contado - esperado
  diferenca_pct    numeric,
  valor_perda_rs   numeric default 0,      -- |diferença| x valor_unitario
  status           text not null,          -- ok | alerta | critico
  gerou_recontagem boolean default false,
  criada_em        timestamptz not null default now()
);

-- 8) ALERTAS (o que vai pro WhatsApp do gerente)
create table if not exists inv_alertas (
  id               uuid primary key default gen_random_uuid(),
  casa_id          uuid references inv_casas(id),
  tipo             text not null,          -- variancia | padrao | auditoria | ia_divergencia
  severidade       text not null default 'alta', -- alta | critica
  mensagem         text not null,
  item_id          uuid references inv_itens(id),
  funcionario_id   uuid references inv_funcionarios(id),
  enviado_whatsapp boolean default false,
  resolvido        boolean default false,
  criado_em        timestamptz not null default now()
);

-- 9) AUDITORIAS (recontagem surpresa via WhatsApp do gerente)
--    Regra: itens que deram problema da última vez + sorteio ponderado p/ risco + 5 aleatórios
create table if not exists inv_auditorias (
  id               uuid primary key default gen_random_uuid(),
  casa_id          uuid references inv_casas(id),
  gerente_id       uuid references inv_funcionarios(id),
  data_ref         date not null,
  itens_problema   jsonb default '[]'::jsonb,  -- itens com variância na última contagem
  itens_alto_risco jsonb default '[]'::jsonb,  -- sorteio ponderado p/ maior risco/valor
  itens_aleatorios jsonb default '[]'::jsonb,  -- 5 sorteados livres
  respostas        jsonb default '[]'::jsonb,  -- respostas do gerente via WhatsApp
  status           text not null default 'enviada', -- enviada | respondida | divergente | ok
  criada_em        timestamptz not null default now(),
  respondida_em    timestamptz
);

-- 10) PADRÕES (IA caça padrão de roubo por pessoa/item/dia)
create table if not exists inv_padroes (
  id             uuid primary key default gen_random_uuid(),
  casa_id        uuid references inv_casas(id),
  funcionario_id uuid references inv_funcionarios(id),
  item_id        uuid references inv_itens(id),
  descricao      text not null,            -- "Toda terça que o Jonas conta, falta gin"
  ocorrencias    int default 0,
  confianca      numeric,                  -- 0-1
  periodo_ini    date,
  periodo_fim    date,
  criado_em      timestamptz not null default now()
);

-- ÍNDICES (performance dos cruzamentos e relatórios)
create index if not exists idx_itens_casa     on inv_itens(casa_id);
create index if not exists idx_itens_barras    on inv_itens(codigo_barras);
create index if not exists idx_itens_master    on inv_itens(codigo_master);
create index if not exists idx_esperado_lookup on inv_esperado(casa_id, item_id, data_ref);
create index if not exists idx_contagem_casa   on inv_contagens(casa_id, criada_em);
create index if not exists idx_citens_contagem on inv_contagem_itens(contagem_id);
create index if not exists idx_var_casa_data   on inv_variancias(casa_id, data_ref);
create index if not exists idx_var_status      on inv_variancias(status);
create index if not exists idx_alertas_casa    on inv_alertas(casa_id, resolvido);
create index if not exists idx_padroes_func    on inv_padroes(funcionario_id);
