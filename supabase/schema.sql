-- VYRA Production Demo Schema
-- Supabase PostgreSQL. Run this once in Supabase SQL Editor.

create extension if not exists pgcrypto;

do $$ begin
  create type public.app_role as enum ('Student','Preceptor','CI','Department Supervisor');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.request_status as enum ('Pending','Approved','Rejected');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.attendance_status as enum ('Present','Late','Absent','OFF');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.evaluation_type as enum ('department','preceptor');
exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default 'VYRA User',
  email text,
  role public.app_role not null default 'Student',
  approval_status public.request_status not null default 'Approved',
  staff_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.sections (
  id uuid primary key default gen_random_uuid(),
  department text not null,
  section text not null,
  building text not null,
  floor text,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table if not exists public.students (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid unique references public.profiles(id) on delete cascade,
  student_id text unique not null,
  created_at timestamptz not null default now()
);

create table if not exists public.placements (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  section_id uuid not null references public.sections(id) on delete restrict,
  preceptor_id uuid references public.profiles(id) on delete set null,
  ci_id uuid references public.profiles(id) on delete set null,
  start_date date,
  end_date date,
  status text not null default 'Active',
  created_at timestamptz not null default now()
);

create table if not exists public.schedule_entries (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  work_date date not null,
  shift text not null check (shift in ('DAY','NIGHT','OFF')),
  created_at timestamptz not null default now(),
  unique(student_id, work_date)
);

create table if not exists public.attendance (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  attendance_date date not null,
  status public.attendance_status not null default 'Present',
  check_in timestamptz,
  check_out timestamptz,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(student_id, attendance_date)
);

create table if not exists public.learning_videos (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  storage_path text not null,
  uploader_id uuid not null references public.profiles(id) on delete restrict,
  section_id uuid references public.sections(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.learning_progress (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  module_key text not null,
  completed boolean not null default false,
  reflection text,
  updated_at timestamptz not null default now(),
  unique(student_id, module_key)
);

create table if not exists public.requests (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  request_type text not null,
  request_date date not null,
  details text not null,
  attachment_path text,
  status public.request_status not null default 'Pending',
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  subject text not null,
  body text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.evaluations (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  evaluation_type public.evaluation_type not null,
  section_id uuid references public.sections(id) on delete set null,
  preceptor_id uuid references public.profiles(id) on delete set null,
  rating int not null check (rating between 1 and 5),
  comments text,
  created_at timestamptz not null default now()
);

create table if not exists public.role_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  requested_role public.app_role not null,
  staff_id text not null,
  verification_path text,
  status public.request_status not null default 'Pending',
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_sections_created_by on public.sections(created_by);
create index if not exists idx_placements_student on public.placements(student_id);
create index if not exists idx_placements_section on public.placements(section_id);
create index if not exists idx_schedule_student_date on public.schedule_entries(student_id, work_date);
create index if not exists idx_attendance_student_date on public.attendance(student_id, attendance_date);
create index if not exists idx_learning_videos_section on public.learning_videos(section_id);
create index if not exists idx_requests_student on public.requests(student_id);
create index if not exists idx_evaluations_student on public.evaluations(student_id);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name','VYRA User'),
    new.email
  )
  on conflict (id) do update
    set full_name = excluded.full_name, email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

create or replace function public.owns_student(p_student uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.students s where s.id=p_student and s.profile_id=auth.uid()); $$;

create or replace function public.current_role()
returns public.app_role
language sql stable security definer set search_path = public
as $$ select role from public.profiles where id = auth.uid(); $$;

create or replace function public.is_staff()
returns boolean
language sql stable security definer set search_path = public
as $$ select coalesce(public.current_role() in ('Preceptor','CI','Department Supervisor'), false); $$;

create or replace function public.is_management()
returns boolean
language sql stable security definer set search_path = public
as $$ select coalesce(public.current_role() in ('CI','Department Supervisor'), false); $$;

create or replace function public.can_see_student(p_student uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.students s where s.id=p_student and s.profile_id=auth.uid()
  )
  or exists (
    select 1
    from public.placements p
    where p.student_id=p_student
      and (
        p.preceptor_id=auth.uid()
        or p.ci_id=auth.uid()
      )
  )
  or public.current_role()='Department Supervisor';
$$;

alter table public.profiles enable row level security;
alter table public.sections enable row level security;
alter table public.students enable row level security;
alter table public.placements enable row level security;
alter table public.schedule_entries enable row level security;
alter table public.attendance enable row level security;
alter table public.learning_videos enable row level security;
alter table public.learning_progress enable row level security;
alter table public.requests enable row level security;
alter table public.messages enable row level security;
alter table public.evaluations enable row level security;
alter table public.role_requests enable row level security;

drop policy if exists profiles_self on public.profiles;
create policy profiles_self on public.profiles for select using (id=auth.uid() or public.is_management());

drop policy if exists profiles_update_self on public.profiles;
-- Role changes are not allowed from the browser.

drop policy if exists sections_read on public.sections;
create policy sections_read on public.sections for select using (auth.uid() is not null);

drop policy if exists sections_ci_insert on public.sections;
create policy sections_ci_insert on public.sections for insert with check (public.current_role()='CI' and created_by=auth.uid());

drop policy if exists sections_ci_delete on public.sections;
create policy sections_ci_delete on public.sections for delete using (public.current_role()='CI' and created_by=auth.uid());

drop policy if exists students_read on public.students;
create policy students_read on public.students for select using (public.can_see_student(id));

drop policy if exists students_insert_staff on public.students;
create policy students_insert_staff on public.students for insert with check (public.is_management());

drop policy if exists students_update_staff on public.students;
create policy students_update_staff on public.students for update using (public.is_management());

drop policy if exists placements_read on public.placements;
create policy placements_read on public.placements for select using (public.can_see_student(student_id));

drop policy if exists placements_manage on public.placements;
create policy placements_manage on public.placements for all using (public.is_management()) with check (public.is_management());

drop policy if exists schedule_read on public.schedule_entries;
create policy schedule_read on public.schedule_entries for select using (public.can_see_student(student_id));

drop policy if exists schedule_manage on public.schedule_entries;
create policy schedule_manage on public.schedule_entries for all using (public.is_management()) with check (public.is_management());

drop policy if exists attendance_read on public.attendance;
create policy attendance_read on public.attendance for select using (public.can_see_student(student_id));

drop policy if exists attendance_student_insert on public.attendance;
create policy attendance_student_insert on public.attendance for insert with check (
  public.owns_student(student_id)
);

drop policy if exists attendance_student_update on public.attendance;
create policy attendance_student_update on public.attendance for update using (
  public.owns_student(student_id)
) with check (
  public.owns_student(student_id)
);

drop policy if exists attendance_staff_manage on public.attendance;
create policy attendance_staff_manage on public.attendance for all using (public.is_staff()) with check (public.is_staff());

drop policy if exists videos_read on public.learning_videos;
create policy videos_read on public.learning_videos for select using (auth.uid() is not null);

drop policy if exists videos_staff_insert on public.learning_videos;
create policy videos_staff_insert on public.learning_videos for insert with check (public.is_staff() and uploader_id=auth.uid());

drop policy if exists videos_staff_delete on public.learning_videos;
create policy videos_staff_delete on public.learning_videos for delete using (public.is_staff() and uploader_id=auth.uid());

drop policy if exists progress_self on public.learning_progress;
create policy progress_self on public.learning_progress for all using (
  public.owns_student(student_id)
) with check (
  public.owns_student(student_id)
);

drop policy if exists progress_staff_read on public.learning_progress;
create policy progress_staff_read on public.learning_progress for select using (public.is_staff());

drop policy if exists requests_read on public.requests;
create policy requests_read on public.requests for select using (public.can_see_student(student_id));

drop policy if exists requests_student_insert on public.requests;
create policy requests_student_insert on public.requests for insert with check (
  public.owns_student(student_id)
);

drop policy if exists requests_manage on public.requests;
create policy requests_manage on public.requests for update using (public.is_staff()) with check (public.is_staff());

drop policy if exists messages_read on public.messages;
create policy messages_read on public.messages for select using (
  student_id in (select id from public.students where profile_id=auth.uid())
  or recipient_id=auth.uid()
);

drop policy if exists messages_student_insert on public.messages;
create policy messages_student_insert on public.messages for insert with check (
  student_id in (select id from public.students where profile_id=auth.uid())
);

drop policy if exists evaluations_management_read on public.evaluations;
create policy evaluations_management_read on public.evaluations for select using (public.is_management());

drop policy if exists evaluations_student_insert on public.evaluations;
create policy evaluations_student_insert on public.evaluations for insert with check (
  student_id in (select id from public.students where profile_id=auth.uid())
);

drop policy if exists role_requests_self_insert on public.role_requests;
create policy role_requests_self_insert on public.role_requests for insert with check (user_id=auth.uid());

drop policy if exists role_requests_self_read on public.role_requests;
create policy role_requests_self_read on public.role_requests for select using (user_id=auth.uid() or public.current_role()='Department Supervisor');

drop policy if exists role_requests_management_update on public.role_requests;
create policy role_requests_management_update on public.role_requests for update using (public.current_role()='Department Supervisor') with check (public.current_role()='Department Supervisor');

-- Storage buckets.
insert into storage.buckets (id, name, public) values
  ('learning-videos','learning-videos',false),
  ('verification-docs','verification-docs',false),
  ('request-attachments','request-attachments',false)
on conflict (id) do nothing;

drop policy if exists learning_videos_read on storage.objects;
create policy learning_videos_read on storage.objects for select using (
  bucket_id='learning-videos' and auth.uid() is not null
);

drop policy if exists learning_videos_upload on storage.objects;
create policy learning_videos_upload on storage.objects for insert with check (
  bucket_id='learning-videos' and public.is_staff() and (storage.foldername(name))[1]=auth.uid()::text
);

drop policy if exists learning_videos_delete on storage.objects;
create policy learning_videos_delete on storage.objects for delete using (
  bucket_id='learning-videos' and public.is_staff() and owner_id=auth.uid()::text
);

drop policy if exists verification_upload on storage.objects;
create policy verification_upload on storage.objects for insert with check (
  bucket_id='verification-docs' and auth.uid()::text=(storage.foldername(name))[1]
);

drop policy if exists verification_read_management on storage.objects;
create policy verification_read_management on storage.objects for select using (
  bucket_id='verification-docs' and public.current_role()='Department Supervisor'
);

drop policy if exists request_attachment_read on storage.objects;
create policy request_attachment_read on storage.objects for select using (
  bucket_id='request-attachments' and (
    auth.uid()::text=(storage.foldername(name))[1] or public.is_staff()
  )
);

drop policy if exists request_attachment_upload on storage.objects;
create policy request_attachment_upload on storage.objects for insert with check (
  bucket_id='request-attachments' and auth.uid()::text=(storage.foldername(name))[1]
);

-- Bootstrap a first Department Supervisor manually after signup:
-- update public.profiles set role='Department Supervisor', approval_status='Approved'
-- where email='YOUR_EMAIL';
