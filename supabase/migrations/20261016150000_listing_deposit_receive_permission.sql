-- Add a dedicated permission for receiving listing deposits and issuing receipts.
insert into public.dv_accounting_permission_catalog(code,module,label,description,sort_order)
values ('listings.deposit.receive','Listings','Receive listing deposits','Record deposits received for a listing, post them to Real Estate Trust, and issue deposit receipts.',116)
on conflict (code) do update set module=excluded.module,label=excluded.label,description=excluded.description,sort_order=excluded.sort_order;
