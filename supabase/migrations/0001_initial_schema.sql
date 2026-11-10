-- =====================================================================
-- Wanderbook: initial schema (step 2)
-- Run ONCE in Supabase: SQL Editor -> New query -> paste all -> Run.
--
-- Design rules:
--   * Every table has Row Level Security (RLS) on.
--   * The browser can only READ, and only what it's allowed to see.
--   * All game actions (create book, write page, guess, pass) will go
--     through database functions we add in later steps, so the rules of
--     the game are enforced on the server, never trusted to the browser.
--   * Secrets live in their own tables: a page's country (page_locations)
--     and the owner's lie (book_secrets).
-- =====================================================================


-- ---------------------------------------------------------------------
-- TABLES
-- ---------------------------------------------------------------------

-- One row per user. Private: users can only ever read their own row.
create table public.profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  alias            text not null check (alias ~ '^[A-Za-z0-9_]{3,24}$'),
  country_code     text not null check (country_code ~ '^[A-Z]{2}$'),  -- ISO code, e.g. NG, TH
  city             text not null check (char_length(city) between 1 and 80),
  date_of_birth    date not null,
  points           integer not null default 0,
  book_credits     integer not null default 1 check (book_credits >= 0), -- books you're allowed to start
  drops            integer not null default 0,                           -- books you let expire
  accepting_books  boolean not null default true,
  created_at       timestamptz not null default now()
);
create unique index profiles_alias_unique on public.profiles (lower(alias));

-- A book. The owner's cover page lives here (it's page 1).
create table public.books (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null references public.profiles (id) on delete cascade,
  owner_signed_as  text not null check (char_length(owner_signed_as) between 1 and 24),
  origin_country   text not null check (origin_country ~ '^[A-Z]{2}$'),
  origin_city      text not null,
  vibe             text not null check (vibe in ('cozy', 'deep_end', 'chaos', 'mixed')),
  max_pages        smallint not null default 10 check (max_pages between 4 and 20),
  cover_note       text not null check (char_length(cover_note) between 1 and 500),
  owner_question   text not null check (char_length(owner_question) between 5 and 200),
  truths           text[] not null check (array_length(truths, 1) = 3),
  status           text not null default 'traveling'
                   check (status in ('traveling', 'returned', 'revealed')),
  pages_written    smallint not null default 1,
  created_at       timestamptz not null default now(),
  returned_at      timestamptz
);
create index books_owner_idx on public.books (owner_id);
create index books_status_idx on public.books (status);

-- Which of the three statements is the lie. Nobody can read this directly.
create table public.book_secrets (
  book_id    uuid primary key references public.books (id) on delete cascade,
  lie_index  smallint not null check (lie_index between 0 and 2)
);

-- A stranger's page.
create table public.pages (
  id              uuid primary key default gen_random_uuid(),
  book_id         uuid not null references public.books (id) on delete cascade,
  page_number     smallint not null check (page_number >= 2),
  writer_id       uuid references public.profiles (id) on delete set null,
  signed_as       text not null check (char_length(signed_as) between 1 and 24),
  answers         jsonb not null
                  check (jsonb_typeof(answers) = 'array' and octet_length(answers::text) <= 20000),
  chain_question  text not null check (char_length(chain_question) between 5 and 200),
  created_at      timestamptz not null default now(),
  unique (book_id, page_number),
  unique (book_id, writer_id)          -- you can only write in a book once
);

-- Where each page was written. Revealed only after you guess.
create table public.page_locations (
  page_id       uuid primary key references public.pages (id) on delete cascade,
  country_code  text not null check (country_code ~ '^[A-Z]{2}$'),
  city          text not null
);

-- Who is holding which book, and how each hold ended.
create table public.holds (
  id          uuid primary key default gen_random_uuid(),
  book_id     uuid not null references public.books (id) on delete cascade,
  holder_id   uuid not null references public.profiles (id) on delete cascade,
  started_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  outcome     text not null default 'holding'
              check (outcome in ('holding', 'written', 'passed', 'expired')),
  ended_at    timestamptz
);
-- THE core rule, enforced by the database itself:
-- a book can only be in one person's hands at a time...
create unique index holds_one_holder_per_book on public.holds (book_id) where outcome = 'holding';
-- ...and a person can only hold one book at a time.
create unique index holds_one_book_per_holder on public.holds (holder_id) where outcome = 'holding';
create index holds_expiry_idx on public.holds (expires_at) where outcome = 'holding';

-- Country guesses on pages.
create table public.guesses (
  page_id          uuid not null references public.pages (id) on delete cascade,
  guesser_id       uuid not null references public.profiles (id) on delete cascade,
  guessed_country  text not null check (guessed_country ~ '^[A-Z]{2}$'),
  correct          boolean not null,
  created_at       timestamptz not null default now(),
  primary key (page_id, guesser_id)
);

-- Guesses at the owner's two-truths-and-a-lie.
create table public.lie_guesses (
  book_id      uuid not null references public.books (id) on delete cascade,
  guesser_id   uuid not null references public.profiles (id) on delete cascade,
  guess_index  smallint not null check (guess_index between 0 and 2),
  created_at   timestamptz not null default now(),
  primary key (book_id, guesser_id)
);

-- Margin notes: one per person per book.
create table public.margin_notes (
  id          uuid primary key default gen_random_uuid(),
  book_id     uuid not null references public.books (id) on delete cascade,
  page_id     uuid not null references public.pages (id) on delete cascade,
  writer_id   uuid references public.profiles (id) on delete set null,
  sticker     text check (sticker is null or char_length(sticker) <= 16),
  body        text check (body is null or char_length(body) <= 60),
  created_at  timestamptz not null default now(),
  check (sticker is not null or body is not null),
  unique (book_id, writer_id)
);

-- Reports from users. Only readable by you in the Supabase dashboard.
create table public.reports (
  id           uuid primary key default gen_random_uuid(),
  reporter_id  uuid references public.profiles (id) on delete set null,
  book_id      uuid references public.books (id) on delete cascade,
  page_id      uuid references public.pages (id) on delete cascade,
  note_id      uuid references public.margin_notes (id) on delete cascade,
  reason       text not null
               check (reason in ('contact_info', 'harassment', 'sexual', 'hate', 'spam', 'other')),
  details      text check (details is null or char_length(details) <= 500),
  status       text not null default 'open' check (status in ('open', 'actioned', 'dismissed')),
  created_at   timestamptz not null default now()
);


-- ---------------------------------------------------------------------
-- HELPER FUNCTIONS (used by the security rules below)
-- "security definer" lets them check facts the user can't read directly,
-- and they only ever return true/false (or an id), never secret data.
-- ---------------------------------------------------------------------

create or replace function public.is_current_holder(p_book uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.holds h
    where h.book_id = p_book
      and h.holder_id = (select auth.uid())
      and h.outcome = 'holding'
      and h.expires_at > now()
  );
$$;

create or replace function public.is_book_owner(p_book uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.books b
    where b.id = p_book and b.owner_id = (select auth.uid())
  );
$$;

create or replace function public.is_book_home(p_book uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.books b
    where b.id = p_book and b.status in ('returned', 'revealed')
  );
$$;

create or replace function public.is_page_writer(p_page uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.pages p
    where p.id = p_page and p.writer_id = (select auth.uid())
  );
$$;

create or replace function public.is_note_writer(p_note uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.margin_notes n
    where n.id = p_note and n.writer_id = (select auth.uid())
  );
$$;

create or replace function public.has_guessed(p_page uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.guesses g
    where g.page_id = p_page and g.guesser_id = (select auth.uid())
  );
$$;

create or replace function public.page_book(p_page uuid)
returns uuid language sql stable security definer set search_path = ''
as $$
  select p.book_id from public.pages p where p.id = p_page;
$$;

revoke execute on function
  public.is_current_holder(uuid), public.is_book_owner(uuid), public.is_book_home(uuid),
  public.is_page_writer(uuid), public.is_note_writer(uuid), public.has_guessed(uuid),
  public.page_book(uuid)
from public, anon;
grant execute on function
  public.is_current_holder(uuid), public.is_book_owner(uuid), public.is_book_home(uuid),
  public.is_page_writer(uuid), public.is_note_writer(uuid), public.has_guessed(uuid),
  public.page_book(uuid)
to authenticated;


-- ---------------------------------------------------------------------
-- PERMISSIONS
-- Start from "nothing allowed", then grant only what's needed.
-- Logged-out visitors (anon) get nothing at all.
-- ---------------------------------------------------------------------

revoke all on
  public.profiles, public.books, public.book_secrets, public.pages, public.page_locations,
  public.holds, public.guesses, public.lie_guesses, public.margin_notes, public.reports
from anon, authenticated;

-- Profiles: read your own, create your own, edit a few safe fields.
-- (Points, credits and drops can only be changed by server functions.)
grant select on public.profiles to authenticated;
grant insert (id, alias, country_code, city, date_of_birth) on public.profiles to authenticated;
grant update (alias, city, accepting_books) on public.profiles to authenticated;

grant select on public.books to authenticated;
-- writer_id is deliberately NOT readable, so strangers can't link pages to accounts.
grant select (id, book_id, page_number, signed_as, answers, chain_question, created_at)
  on public.pages to authenticated;
grant select on public.page_locations to authenticated;
grant select on public.holds to authenticated;
grant select on public.guesses to authenticated;
grant select on public.lie_guesses to authenticated;
grant select (id, book_id, page_id, sticker, body, created_at)
  on public.margin_notes to authenticated;
-- book_secrets and reports: no access at all from the app.


-- ---------------------------------------------------------------------
-- ROW LEVEL SECURITY
-- ---------------------------------------------------------------------

alter table public.profiles       enable row level security;
alter table public.books          enable row level security;
alter table public.book_secrets   enable row level security;
alter table public.pages          enable row level security;
alter table public.page_locations enable row level security;
alter table public.holds          enable row level security;
alter table public.guesses        enable row level security;
alter table public.lie_guesses    enable row level security;
alter table public.margin_notes   enable row level security;
alter table public.reports        enable row level security;

-- Profiles
create policy "profiles: read own" on public.profiles
  for select to authenticated
  using (id = (select auth.uid()));

create policy "profiles: create own, adults only" on public.profiles
  for insert to authenticated
  with check (
    id = (select auth.uid())
    and date_of_birth <= (current_date - interval '18 years')
  );

create policy "profiles: update own" on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- Books: the owner always, and whoever is holding it right now.
create policy "books: owner or current holder" on public.books
  for select to authenticated
  using (owner_id = (select auth.uid()) or public.is_current_holder(id));

-- Pages: the current holder reads everything written so far; the owner
-- only once the book is home; and you can always reread your own page.
create policy "pages: holder, owner when home, or writer" on public.pages
  for select to authenticated
  using (
    public.is_current_holder(book_id)
    or (public.is_book_owner(book_id) and public.is_book_home(book_id))
    or public.is_page_writer(id)
  );

-- Page locations: only after you've guessed, if you wrote it, or the
-- owner once the book is home.
create policy "page_locations: after guessing, writer, or owner when home" on public.page_locations
  for select to authenticated
  using (
    public.has_guessed(page_id)
    or public.is_page_writer(page_id)
    or (public.is_book_owner(public.page_book(page_id))
        and public.is_book_home(public.page_book(page_id)))
  );

-- Holds, guesses, lie guesses: your own only.
create policy "holds: own" on public.holds
  for select to authenticated
  using (holder_id = (select auth.uid()));

create policy "guesses: own" on public.guesses
  for select to authenticated
  using (guesser_id = (select auth.uid()));

create policy "lie_guesses: own" on public.lie_guesses
  for select to authenticated
  using (guesser_id = (select auth.uid()));

-- Margin notes: same visibility as pages.
create policy "margin_notes: holder, owner when home, or writer" on public.margin_notes
  for select to authenticated
  using (
    public.is_current_holder(book_id)
    or (public.is_book_owner(book_id) and public.is_book_home(book_id))
    or public.is_note_writer(id)
  );

-- book_secrets and reports have RLS on and no policies: fully locked.