-- Радар портфеля: схема PostgreSQL + pgvector для MVP

CREATE EXTENSION IF NOT EXISTS vector;

-- Справочник инструментов
CREATE TABLE instruments (
    figi            text PRIMARY KEY,
    isin            text NOT NULL UNIQUE,
    ticker          text,
    issuer_name     text NOT NULL,
    instrument_type text NOT NULL CHECK (instrument_type IN ('bond', 'share', 'etf', 'other')),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Сырые записи из источников
CREATE TABLE raw_items (
    id           bigserial PRIMARY KEY,
    source       text NOT NULL,          -- t_invest_api, moex_iss, e_disclosure, rss
    external_id  text,
    url          text,
    title        text,
    body         text,
    payload      jsonb,
    published_at timestamptz,
    fetched_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (source, external_id)
);

-- Событие после нормализации и склейки дублей
CREATE TABLE events (
    id          bigserial PRIMARY KEY,
    figi        text NOT NULL REFERENCES instruments (figi),
    occurred_at timestamptz NOT NULL,
    embedding   vector(1024),            -- BGE-M3 dense
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX events_figi_time_idx ON events (figi, occurred_at DESC);

-- Связь события с источниками (одно событие, несколько сообщений)
CREATE TABLE event_sources (
    event_id    bigint NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    raw_item_id bigint NOT NULL REFERENCES raw_items (id),
    PRIMARY KEY (event_id, raw_item_id)
);

-- Результат классификатора, один на событие, общий для всех пользователей
CREATE TABLE classifications (
    event_id        bigint PRIMARY KEY REFERENCES events (id) ON DELETE CASCADE,
    event_type      text NOT NULL,
    severity        text NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
    action_required boolean NOT NULL,
    action_type     text,
    deadline        date,
    summary         text NOT NULL,
    rationale       text NOT NULL,
    confidence      real NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    model           text NOT NULL,       -- например t-pro-it-2.1
    raw_output      jsonb NOT NULL,      -- ответ по schemas/event_classification.schema.json
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- Пользователи и снимки портфеля
CREATE TABLE users (
    id               bigserial PRIMARY KEY,
    telegram_id      bigint NOT NULL UNIQUE,
    consent_given_at timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE positions (
    user_id     bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    figi        text NOT NULL REFERENCES instruments (figi),
    quantity    numeric NOT NULL,
    weight      numeric NOT NULL CHECK (weight BETWEEN 0 AND 1),  -- доля в портфеле
    snapshot_at timestamptz NOT NULL,
    PRIMARY KEY (user_id, figi)
);

-- Персональная лента
CREATE TABLE feed_items (
    id         bigserial PRIMARY KEY,
    user_id    bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    event_id   bigint NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    score      real NOT NULL,
    bucket     text NOT NULL CHECK (bucket IN ('action', 'important', 'background')),
    card       jsonb,                    -- карточка от агента: что случилось, почему важно, источник
    pushed_at  timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, event_id)
);
CREATE INDEX feed_items_user_idx ON feed_items (user_id, created_at DESC);

-- Черновики действий: исполняются только после подтверждения
CREATE TABLE action_drafts (
    id           bigserial PRIMARY KEY,
    feed_item_id bigint NOT NULL REFERENCES feed_items (id) ON DELETE CASCADE,
    action_type  text NOT NULL,
    params       jsonb NOT NULL,         -- параметры фиксируются в момент создания
    status       text NOT NULL DEFAULT 'proposed'
                 CHECK (status IN ('proposed', 'confirmed', 'executed', 'rejected', 'expired', 'failed')),
    expires_at   timestamptz NOT NULL,
    decided_at   timestamptz,
    result       jsonb,
    created_at   timestamptz NOT NULL DEFAULT now()
);

-- Фидбек для дообучения скоринга
CREATE TABLE feedback (
    feed_item_id bigint PRIMARY KEY REFERENCES feed_items (id) ON DELETE CASCADE,
    label        text NOT NULL CHECK (label IN ('useful', 'noise')),
    created_at   timestamptz NOT NULL DEFAULT now()
);

-- Документы эмитентов для RAG
CREATE TABLE documents (
    id           bigserial PRIMARY KEY,
    figi         text REFERENCES instruments (figi),
    doc_type     text NOT NULL,          -- issue_terms, report, other
    url          text NOT NULL UNIQUE,
    published_at timestamptz,
    fetched_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE document_chunks (
    id          bigserial PRIMARY KEY,
    document_id bigint NOT NULL REFERENCES documents (id) ON DELETE CASCADE,
    chunk_no    int NOT NULL,
    content     text NOT NULL,
    embedding   vector(1024) NOT NULL,
    UNIQUE (document_id, chunk_no)
);
CREATE INDEX document_chunks_embedding_idx
    ON document_chunks USING hnsw (embedding vector_cosine_ops);

-- Очередь задач (SELECT ... FOR UPDATE SKIP LOCKED)
CREATE TABLE jobs (
    id         bigserial PRIMARY KEY,
    kind       text NOT NULL,            -- normalize, classify, score, build_card, push
    payload    jsonb NOT NULL,
    status     text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'done', 'failed')),
    attempts   int NOT NULL DEFAULT 0,
    run_after  timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX jobs_queue_idx ON jobs (kind, run_after) WHERE status = 'queued';

-- Журнал вызовов MCP и действий
CREATE TABLE audit_log (
    id         bigserial PRIMARY KEY,
    actor      text NOT NULL,            -- agent, executor, user
    user_id    bigint REFERENCES users (id),
    operation  text NOT NULL,
    details    jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
