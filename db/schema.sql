-- Сводка информационного фона по облигациям портфеля: схема PostgreSQL для MVP

-- Эмитенты и связанные с ними компании
CREATE TABLE companies (
    inn        text PRIMARY KEY CHECK (inn ~ '^([0-9]{10}|[0-9]{12})$'),
    name       text NOT NULL,
    asset_uid  text,                     -- актив в T-Invest API, если компания — эмитент
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Связи между компаниями: поручитель, дочерняя, материнская
CREATE TABLE company_links (
    inn         text NOT NULL REFERENCES companies (inn),
    related_inn text NOT NULL REFERENCES companies (inn),
    relation    text NOT NULL CHECK (relation IN ('guarantor', 'subsidiary', 'parent', 'other')),
    source      text NOT NULL,           -- откуда известна связь: условия выпуска, текст сообщения
    PRIMARY KEY (inn, related_inn, relation)
);

-- Выпуски облигаций
CREATE TABLE instruments (
    figi       text PRIMARY KEY,
    isin       text NOT NULL UNIQUE,
    ticker     text,
    issuer_inn text NOT NULL REFERENCES companies (inn),
    nominal    numeric,
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX instruments_issuer_idx ON instruments (issuer_inn);

-- События выпуска из календаря и окна приёма заявок на оферту
CREATE TABLE bond_events (
    id              bigserial PRIMARY KEY,
    figi            text NOT NULL REFERENCES instruments (figi),
    event_type      text NOT NULL CHECK (event_type IN ('put_offer', 'call_offer', 'redemption', 'amortization', 'coupon', 'default')),
    event_date      date,                -- из GetBondEvents
    window_start    date,                -- начало приёма заявок у эмитента, MOEX ISS
    window_end      date,                -- конец приёма заявок у эмитента, MOEX ISS
    broker_deadline date,                -- window_end минус три рабочих дня, считает код
    source          text NOT NULL,       -- t_invest_api, moex_iss
    updated_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (figi, event_type, event_date)
);

-- Исходные тексты
CREATE TABLE texts (
    id           bigserial PRIMARY KEY,
    source       text NOT NULL,          -- e_disclosure, rating_agency, news
    external_id  text,
    url          text NOT NULL,
    title        text,
    body         text NOT NULL,
    published_at timestamptz NOT NULL,
    fetched_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (source, external_id)
);

-- Запись, извлечённая моделью из текста; одна на текст и событие, общая для всех инвесторов
CREATE TABLE records (
    id                 bigserial PRIMARY KEY,
    text_id            bigint NOT NULL REFERENCES texts (id) ON DELETE CASCADE,
    company_inn        text REFERENCES companies (inn),
    summary            text NOT NULL,     -- что произошло, одна строка, без оценок
    event_type         text NOT NULL,
    concerns_payments  boolean NOT NULL,
    concerns_rating    boolean NOT NULL,
    concerns_terms     boolean NOT NULL,
    event_date         date,
    quote              text NOT NULL,
    status             text NOT NULL CHECK (status IN ('accepted', 'rejected')),
    reject_reason      text,              -- quote_not_found, inn_unknown, forbidden_words
    confidence         real NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    model              text NOT NULL,     -- например t-pro-it-2.1
    raw_output         jsonb NOT NULL,    -- ответ по schemas/event_classification.schema.json
    created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX records_company_time_idx ON records (company_inn, event_date DESC) WHERE status = 'accepted';

-- Связанные компании, упомянутые в записи
CREATE TABLE record_related (
    record_id   bigint NOT NULL REFERENCES records (id) ON DELETE CASCADE,
    related_inn text NOT NULL REFERENCES companies (inn),
    relation    text NOT NULL CHECK (relation IN ('guarantor', 'subsidiary', 'parent', 'other')),
    PRIMARY KEY (record_id, related_inn)
);

-- Инвесторы и снимки портфеля
CREATE TABLE users (
    id               bigserial PRIMARY KEY,
    consent_given_at timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE positions (
    user_id     bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    figi        text NOT NULL REFERENCES instruments (figi),
    quantity    numeric NOT NULL,
    weight      numeric NOT NULL CHECK (weight BETWEEN 0 AND 1),  -- доля в портфеле
    price_pct   numeric,                                           -- цена в процентах номинала
    snapshot_at timestamptz NOT NULL,
    PRIMARY KEY (user_id, figi)
);

-- Уведомления: одна запись о выплатах, рейтинге или условиях по эмитенту из портфеля
CREATE TABLE notifications (
    id         bigserial PRIMARY KEY,
    user_id    bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    record_id  bigint NOT NULL REFERENCES records (id) ON DELETE CASCADE,
    content    jsonb NOT NULL,           -- запись, цитата, ссылка, выпуски инвестора, точка выхода
    sent_at    timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, record_id)
);

-- Еженедельный отчёт инвестора
CREATE TABLE weekly_reports (
    id         bigserial PRIMARY KEY,
    user_id    bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    week_start date NOT NULL,
    content    jsonb NOT NULL,           -- строка на эмитента, точки выхода, доли, цены
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, week_start)
);

-- Отметки инвестора по записям сводки
CREATE TABLE feedback (
    user_id    bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    record_id  bigint NOT NULL REFERENCES records (id) ON DELETE CASCADE,
    label      text NOT NULL CHECK (label IN ('useful', 'off_topic')),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, record_id)
);

-- Очередь задач (SELECT ... FOR UPDATE SKIP LOCKED)
CREATE TABLE jobs (
    id         bigserial PRIMARY KEY,
    kind       text NOT NULL,            -- fetch, extract, verify, refresh_directory, notify, build_weekly_report
    payload    jsonb NOT NULL,
    status     text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'done', 'failed')),
    attempts   int NOT NULL DEFAULT 0,
    run_after  timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX jobs_queue_idx ON jobs (kind, run_after) WHERE status = 'queued';

-- Журнал вызовов MCP и отклонённых записей
CREATE TABLE audit_log (
    id         bigserial PRIMARY KEY,
    actor      text NOT NULL,            -- collector, extractor, verifier, notifier, report, mcp
    user_id    bigint REFERENCES users (id),
    operation  text NOT NULL,
    details    jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
