-- =====================================================================
-- نظام المكتبة — قاعدة بيانات Supabase
-- الزائر يقرأ الكتب فقط. كل كتابة تمر عبر الدالة lib_api التي تتحقق
-- من اسم الأمين ورمزه داخل قاعدة البيانات (الرموز مخزّنة مشفّرة).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- الجداول ----------
create table if not exists settings (
  id          int primary key default 1 check (id = 1),
  name        text not null default 'مكتبة البيت',
  loan_days   int  not null default 30,
  prefix      text not null default 'B-',
  app_url     text not null default '',
  libraries   text[] not null default '{}',
  owners      text[] not null default '{}',
  categories  text[] not null default '{}'
);

create table if not exists staff (
  name      text primary key,
  pin_hash  text not null,
  active    boolean not null default true
);

create table if not exists books (
  num         text primary key,
  title       text not null check (length(trim(title)) > 0),
  author      text not null default '',
  publisher   text not null default '',
  translator  text not null default '',
  category    text not null default '',
  owner       text not null default '',
  library     text not null default '',
  status      text not null default 'متوفر' check (status in ('متوفر','معار','تالف','مفقود')),
  added       text not null default to_char(now() at time zone 'Africa/Algiers','YYYY-MM-DD'),
  note        text not null default '',
  updated_at  timestamptz not null default now()
);

create sequence if not exists loan_seq;
create table if not exists loans (
  id          text primary key default 'L-' || lpad(nextval('loan_seq')::text, 5, '0'),
  num         text not null,
  title       text not null default '',
  borrower    text not null,
  phone       text not null default '',
  role        text not null default '',
  out_date    date not null default (now() at time zone 'Africa/Algiers')::date,
  due_date    date,
  by_name     text not null,
  ret_date    date,
  recv_by     text not null default '',
  cond        text not null default '',
  note        text not null default '',
  created_at  timestamptz not null default now()
);
create index if not exists loans_num_open on loans (num) where ret_date is null;

create sequence if not exists req_seq;
create table if not exists requests (
  id          text primary key default 'R-' || lpad(nextval('req_seq')::text, 5, '0'),
  at          timestamptz not null default now(),
  num         text not null,
  title       text not null default '',
  name        text not null,
  phone       text not null,
  for_who     text not null default 'لنفسه',
  note        text not null default '',
  status      text not null default 'جديد' check (status in ('جديد','مقبول','مرفوض','سُلّم')),
  by_name     text not null default '',
  done_at     date
);

-- إشارات خفيفة للتحديث الفوري عند الأمين (لا تحوي أي بيانات شخصية)
create table if not exists events (
  id    bigserial primary key,
  kind  text not null,
  at    timestamptz not null default now()
);

-- ---------- الصلاحيات (RLS) ----------
alter table settings enable row level security;
alter table staff    enable row level security;
alter table books    enable row level security;
alter table loans    enable row level security;
alter table requests enable row level security;
alter table events   enable row level security;

revoke all on settings, staff, books, loans, requests, events from anon, authenticated;
grant select on books, events to anon, authenticated;

drop policy if exists books_read on books;
create policy books_read on books for select to anon, authenticated using (true);
drop policy if exists events_read on events;
create policy events_read on events for select to anon, authenticated using (true);
-- staff / loans / requests / settings: لا سياسة = لا وصول مباشر لأي زائر

-- ---------- أدوات داخلية ----------
create or replace function _ping(k text) returns void language sql security definer set search_path = public as $$
  delete from events where at < now() - interval '1 day';
  insert into events(kind) values (k);
$$;

create or replace function _auth(p jsonb) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare n text;
begin
  select name into n from staff
   where name = coalesce(p->>'user','') and active
     and pin_hash = crypt(coalesce(p->>'pin',''), pin_hash);
  if n is null then raise exception 'اسم الأمين أو الرمز غير صحيح'; end if;
  return n;
end $$;

create or replace function _digits(v text) returns text language sql immutable set search_path = public as $$
  select regexp_replace(translate(coalesce(v,''), '٠١٢٣٤٥٦٧٨٩', '0123456789'), '\D', '', 'g');
$$;

create or replace function _book(b books) returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object('num',b.num,'title',b.title,'author',b.author,'publisher',b.publisher,'translator',b.translator,
    'category',b.category,'owner',b.owner,'library',b.library,'status',b.status,'added',b.added,'note',b.note);
$$;

create or replace function _loan(l loans) returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object('id',l.id,'num',l.num,'title',l.title,'borrower',l.borrower,'phone',l.phone,'role',l.role,
    'out',coalesce(to_char(l.out_date,'YYYY-MM-DD'),''),'due',coalesce(to_char(l.due_date,'YYYY-MM-DD'),''),
    'by',l.by_name,'ret',coalesce(to_char(l.ret_date,'YYYY-MM-DD'),''),'recvBy',l.recv_by,'cond',l.cond,'note',l.note);
$$;

create or replace function _req(r requests) returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object('id',r.id,'at',to_char(r.at at time zone 'Africa/Algiers','YYYY-MM-DD HH24:MI'),'num',r.num,'title',r.title,
    'name',r.name,'phone',r.phone,'forWho',r.for_who,'note',r.note,'status',r.status,'by',r.by_name,
    'doneAt',coalesce(to_char(r.done_at,'YYYY-MM-DD'),''));
$$;

-- الرقم التالي: أكبر رقم بنفس البادئة + 1
create or replace function _next_nums(cnt int) returns text[]
language plpgsql security definer set search_path = public as $$
declare pre text; mx int; out text[] := '{}';
begin
  perform pg_advisory_xact_lock(4242);
  select prefix into pre from settings where id = 1;
  select coalesce(max((regexp_match(num, '^' || regexp_replace(pre, '([.*+?^${}()|\[\]\\])', '\\\1', 'g') || '(\d+)$', 'i'))[1]::int), 0)
    into mx from books;
  for i in 1..cnt loop out := out || (pre || lpad((mx + i)::text, 4, '0')); end loop;
  return out;
end $$;

-- إضافة قيم جديدة لقوائم الإعدادات (تصنيف، مالك، مكتبة) إن لم تكن موجودة
create or replace function _remember_lists(cat text, own text, lib text) returns void
language sql security definer set search_path = public as $$
  update settings set
    categories = case when coalesce(cat,'') <> '' and not (cat = any(categories)) then categories || cat else categories end,
    owners     = case when coalesce(own,'') <> '' and not (own = any(owners))     then owners || own     else owners end,
    libraries  = case when coalesce(lib,'') <> '' and not (lib = any(libraries))  then libraries || lib  else libraries end
  where id = 1;
$$;

-- =====================================================================
-- الدالة الوحيدة التي يستدعيها التطبيق
-- =====================================================================
create or replace function lib_api(p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  u text; s settings; b books; l loans; r requests;
  res jsonb; t text; nums text[]; ph text; n int; i int; rowj jsonb; mode text;
  added text[] := '{}'; updated int := 0; deleted int := 0; skipped jsonb := '[]'::jsonb;
  today date := (now() at time zone 'Africa/Algiers')::date;
begin
  select * into s from settings where id = 1;

  -- ---------- للجميع ----------
  if p_action = 'init' then
    return jsonb_build_object('ok', true,
      'settings', jsonb_build_object('name', s.name, 'libraries', to_jsonb(s.libraries), 'owners', to_jsonb(s.owners),
        'categories', to_jsonb(s.categories), 'loanDays', s.loan_days, 'prefix', s.prefix, 'appUrl', s.app_url,
        'staff', coalesce((select jsonb_agg(name order by name) from staff where active), '[]'::jsonb)),
      'books', coalesce((select jsonb_agg(_book(x) order by x.num) from books x), '[]'::jsonb));

  elsif p_action = 'book' then
    select * into b from books where upper(num) = upper(p->>'num');
    if not found then raise exception 'لا يوجد كتاب بهذا الرقم'; end if;
    return jsonb_build_object('ok', true, 'book', _book(b));

  elsif p_action = 'request' then
    if coalesce(p->>'website','') <> '' then return jsonb_build_object('ok', true, 'id', 'ok'); end if;
    if length(trim(coalesce(p->>'name',''))) = 0 then raise exception 'الاسم إلزامي'; end if;
    ph := _digits(p->>'phone');
    if ph !~ '^0[567][0-9]{8}$' then raise exception 'رقم الهاتف يجب أن يكون 10 أرقام ويبدأ بـ 05 أو 06 أو 07'; end if;
    select * into b from books where upper(num) = upper(p->>'num');
    if not found then raise exception 'لا يوجد كتاب بهذا الرقم'; end if;
    if exists (select 1 from requests where num = b.num and phone = ph and status in ('جديد','مقبول')) then
      raise exception 'لديك طلب سابق لهذا الكتاب قيد المعالجة'; end if;
    if (select count(*) from requests where phone = ph and at > now() - interval '1 day') >= 5 then
      raise exception 'وصلت إلى الحد الأقصى للطلبات اليوم'; end if;
    insert into requests(num, title, name, phone, for_who, note)
      values (b.num, b.title, left(trim(p->>'name'), 80), ph,
              coalesce(nullif(left(trim(coalesce(p->>'forWho','')), 80), ''), 'لنفسه'), left(trim(coalesce(p->>'note','')), 200))
      returning * into r;
    perform _ping('request');
    return jsonb_build_object('ok', true, 'id', r.id);
  end if;

  -- ---------- للأمين فقط ----------
  u := _auth(p);

  if p_action = 'login' then
    return jsonb_build_object('ok', true, 'user', u);

  elsif p_action = 'bookStaff' then
    select * into b from books where upper(num) = upper(p->>'num');
    if not found then raise exception 'لا يوجد كتاب بهذا الرقم'; end if;
    return jsonb_build_object('ok', true, 'book', _book(b),
      'open', (select _loan(x) from loans x where x.num = b.num and x.ret_date is null order by x.created_at desc limit 1),
      'history', coalesce((select jsonb_agg(_loan(x) order by x.created_at desc) from loans x where x.num = b.num), '[]'::jsonb));

  elsif p_action = 'addBook' then
    if length(trim(coalesce(p->'book'->>'title',''))) = 0 then raise exception 'العنوان إلزامي'; end if;
    n := greatest(1, least(50, coalesce(nullif(p->'book'->>'copies','')::int, 1)));
    if coalesce(trim(p->'book'->>'num'),'') <> '' and n = 1 then
      if exists (select 1 from books where upper(num) = upper(trim(p->'book'->>'num'))) then
        raise exception 'رقم الكتاب % مستعمل من قبل', trim(p->'book'->>'num'); end if;
      nums := array[trim(p->'book'->>'num')];
    else
      nums := _next_nums(n);
    end if;
    insert into books(num, title, author, publisher, translator, category, owner, library, note)
      select x, trim(p->'book'->>'title'), trim(coalesce(p->'book'->>'author','')), trim(coalesce(p->'book'->>'publisher','')),
             trim(coalesce(p->'book'->>'translator','')), trim(coalesce(p->'book'->>'category','')), trim(coalesce(p->'book'->>'owner','')),
             coalesce(nullif(trim(coalesce(p->'book'->>'library','')), ''), s.libraries[1], ''),
             coalesce(nullif(trim(coalesce(p->'book'->>'note','')), ''), 'أضافه ' || u)
        from unnest(nums) x;
    perform _remember_lists(p->'book'->>'category', p->'book'->>'owner', p->'book'->>'library');
    return jsonb_build_object('ok', true, 'added', to_jsonb(nums));

  elsif p_action = 'lend' then
    if length(trim(coalesce(p->>'borrower',''))) = 0 then raise exception 'اسم المستعير إلزامي'; end if;
    ph := _digits(p->>'phone');
    if ph !~ '^0[567][0-9]{8}$' then raise exception 'رقم الهاتف إجباري: 10 أرقام تبدأ بـ 05 أو 06 أو 07'; end if;
    select * into b from books where upper(num) = upper(p->>'num') for update;
    if not found then raise exception 'لا يوجد كتاب بهذا الرقم'; end if;
    if b.status <> 'متوفر' then raise exception 'الكتاب غير متاح للإعارة، حالته: %', b.status; end if;
    insert into loans(num, title, borrower, phone, role, out_date, due_date, by_name, note)
      values (b.num, b.title, trim(p->>'borrower'), ph, trim(coalesce(p->>'role','')),
              coalesce(nullif(p->>'out','')::date, today),
              coalesce(nullif(p->>'due','')::date, coalesce(nullif(p->>'out','')::date, today) + s.loan_days),
              u, trim(coalesce(p->>'note','')))
      returning * into l;
    update books set status = 'معار', updated_at = now() where num = b.num;
    perform _ping('loan');
    return jsonb_build_object('ok', true, 'loanId', l.id, 'by', u);

  elsif p_action = 'returnBook' then
    select * into b from books where upper(num) = upper(p->>'num') for update;
    if not found then raise exception 'لا يوجد كتاب بهذا الرقم'; end if;
    select * into l from loans where num = b.num and ret_date is null order by created_at desc limit 1 for update;
    if not found then raise exception 'لا توجد إعارة مفتوحة لهذا الكتاب'; end if;
    update loans set ret_date = coalesce(nullif(p->>'ret','')::date, today), recv_by = u,
                     cond = coalesce(nullif(p->>'cond',''), 'سليم'),
                     note = case when coalesce(trim(p->>'note'),'') = '' then note
                                 when note = '' then trim(p->>'note') else note || ' | ' || trim(p->>'note') end
      where id = l.id;
    update books set updated_at = now(), status = case coalesce(nullif(p->>'cond',''), 'سليم')
        when 'مفقود' then 'مفقود' when 'تالف' then 'تالف' else 'متوفر' end
      where num = b.num;
    perform _ping('loan');
    return jsonb_build_object('ok', true, 'status', (select status from books where num = b.num), 'by', u);

  elsif p_action = 'loans' then
    return jsonb_build_object('ok', true, 'loans', coalesce((select jsonb_agg(_loan(x) order by x.created_at) from loans x), '[]'::jsonb));

  elsif p_action = 'requests' then
    return jsonb_build_object('ok', true, 'requests', coalesce((select jsonb_agg(_req(x) order by x.at desc) from requests x), '[]'::jsonb));

  elsif p_action = 'setRequest' then
    if coalesce(p->>'status','') not in ('جديد','مقبول','مرفوض','سُلّم') then raise exception 'حالة غير معروفة'; end if;
    update requests set status = p->>'status', by_name = u, done_at = today where id = p->>'id' returning * into r;
    if not found then raise exception 'الطلب غير موجود'; end if;
    perform _ping('request');
    return jsonb_build_object('ok', true, 'status', r.status);

  -- ---------- الاستيراد من الإكسل ----------
  -- mode: add (إضافة فقط) | upsert (إضافة وتحديث) | replace (استبدال كامل)
  elsif p_action = 'import' then
    mode := coalesce(p->>'mode', 'add');
    if mode not in ('add','upsert','replace') then raise exception 'وضع استيراد غير معروف'; end if;
    if jsonb_typeof(p->'rows') <> 'array' or jsonb_array_length(p->'rows') = 0 then raise exception 'الملف لا يحوي كتباً'; end if;

    if mode = 'replace' then
      -- لا نحذف كتاباً معاراً حالياً إن لم يكن في الملف
      select string_agg(x.num || ' (' || x.title || ')', '، ') into t
        from books x
       where x.status = 'معار'
         and upper(x.num) not in (select upper(trim(e->>'num')) from jsonb_array_elements(p->'rows') e where coalesce(trim(e->>'num'),'') <> '');
      if t is not null then
        raise exception 'لا يمكن الاستبدال: هذه الكتب معارة حالياً وغير موجودة في الملف: %', t; end if;
      delete from books x
       where upper(x.num) not in (select upper(trim(e->>'num')) from jsonb_array_elements(p->'rows') e where coalesce(trim(e->>'num'),'') <> '');
      get diagnostics deleted = row_count;
    end if;

    i := 0;
    for rowj in select * from jsonb_array_elements(p->'rows') loop
      i := i + 1;
      if length(trim(coalesce(rowj->>'title',''))) = 0 then
        skipped := skipped || jsonb_build_object('row', i, 'reason', 'العنوان فارغ'); continue; end if;
      if coalesce(trim(rowj->>'num'),'') <> '' then
        if exists (select 1 from books where upper(num) = upper(trim(rowj->>'num'))) then
          if mode = 'add' then
            skipped := skipped || jsonb_build_object('row', i, 'reason', 'الرقم ' || trim(rowj->>'num') || ' موجود مسبقاً'); continue;
          end if;
          update books set title = trim(rowj->>'title'), author = trim(coalesce(rowj->>'author','')), publisher = trim(coalesce(rowj->>'publisher','')),
                 translator = trim(coalesce(rowj->>'translator','')), category = trim(coalesce(rowj->>'category','')),
                 owner = trim(coalesce(rowj->>'owner','')), library = coalesce(nullif(trim(coalesce(rowj->>'library','')), ''), library),
                 note = trim(coalesce(rowj->>'note', note)), updated_at = now()
           where upper(num) = upper(trim(rowj->>'num'));
          updated := updated + 1;
        else
          insert into books(num, title, author, publisher, translator, category, owner, library, note)
            values (trim(rowj->>'num'), trim(rowj->>'title'), trim(coalesce(rowj->>'author','')), trim(coalesce(rowj->>'publisher','')),
                    trim(coalesce(rowj->>'translator','')), trim(coalesce(rowj->>'category','')), trim(coalesce(rowj->>'owner','')),
                    coalesce(nullif(trim(coalesce(rowj->>'library','')), ''), s.libraries[1], ''), trim(coalesce(rowj->>'note','')));
          added := added || trim(rowj->>'num');
        end if;
      else
        n := greatest(1, least(50, coalesce(nullif(regexp_replace(coalesce(rowj->>'copies',''), '\D', '', 'g'), '')::int, 1)));
        nums := _next_nums(n);
        insert into books(num, title, author, publisher, translator, category, owner, library, note)
          select x, trim(rowj->>'title'), trim(coalesce(rowj->>'author','')), trim(coalesce(rowj->>'publisher','')),
                 trim(coalesce(rowj->>'translator','')), trim(coalesce(rowj->>'category','')), trim(coalesce(rowj->>'owner','')),
                 coalesce(nullif(trim(coalesce(rowj->>'library','')), ''), s.libraries[1], ''), trim(coalesce(rowj->>'note',''))
            from unnest(nums) x;
        added := added || nums;
      end if;
      perform _remember_lists(rowj->>'category', rowj->>'owner', rowj->>'library');
    end loop;
    perform _ping('import');
    return jsonb_build_object('ok', true, 'added', to_jsonb(added), 'updated', updated, 'deleted', deleted, 'skipped', skipped);

  -- ---------- التصدير ----------
  elsif p_action = 'export' then
    return jsonb_build_object('ok', true,
      'books',    coalesce((select jsonb_agg(_book(x) order by x.num) from books x), '[]'::jsonb),
      'loans',    coalesce((select jsonb_agg(_loan(x) order by x.created_at) from loans x), '[]'::jsonb),
      'requests', coalesce((select jsonb_agg(_req(x) order by x.at) from requests x), '[]'::jsonb),
      'settings', jsonb_build_object('name', s.name, 'categories', to_jsonb(s.categories), 'owners', to_jsonb(s.owners), 'libraries', to_jsonb(s.libraries)));
  end if;

  raise exception 'إجراء غير معروف';
end $$;

-- لا أحد يستدعي الأدوات الداخلية مباشرة، والتطبيق يستدعي lib_api فقط
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function lib_api(text, jsonb) to anon, authenticated;

-- التحديث الفوري
do $$ begin
  begin alter publication supabase_realtime add table books;  exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table events; exception when duplicate_object then null; end;
end $$;

-- الهاتف إجباري في كل إعارة جديدة (حماية إضافية داخل الجدول نفسه)
create or replace function _loan_phone_check() returns trigger language plpgsql set search_path = public as $$
begin
  if coalesce(new.phone,'') !~ '^0[567][0-9]{8}$' then
    raise exception 'رقم الهاتف إجباري: 10 أرقام تبدأ بـ 05 أو 06 أو 07';
  end if;
  return new;
end $$;
drop trigger if exists loans_phone_required on loans;
create trigger loans_phone_required before insert on loans for each row execute function _loan_phone_check();
revoke execute on function _loan_phone_check() from public, anon, authenticated;
