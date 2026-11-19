import { useEffect, useRef, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";



type Request = { user_id: string; email: string; requested_at: string };
export function AccessRequests({client,raceId,onApproved}: {client:SupabaseClient;raceId:string;onApproved?:()=>void}) {

  const [items,setItems]=useState<Request[]>([]);
  const [busy,setBusy]=useState(false);
  const [message,setMessage]=useState("");
  const [error,setError]=useState("");
  const [pending,setPending]=useState<{item:Request;approve:boolean;role:"viewer"|"editor"}|null>(null);
  const lock=useRef(false);
  const button="min-h-11 rounded border border-border px-3 disabled:opacity-50";
  async function rpc(name:string,args:Record<string,unknown>) {
    const abort=new AbortController();
    const timer=setTimeout(()=>abort.abort(),15000);
    try { const result=await client.rpc(name,args).abortSignal(abort.signal); if(result.error) throw result.error; return result.data; }
    finally {clearTimeout(timer);}
  }
  async function load() {
    if(!raceId || lock.current) return;
    lock.current=true;setBusy(true);setError("");setPending(null);
    try {setItems(await rpc("race_access_requests",{p_race:raceId}) ?? []);}
    catch {setItems([]);setError("Unable to load access requests. Try refreshing.");}
    finally {lock.current=false;setBusy(false);}
  }
  useEffect(()=>{void load();},[client,raceId]);
  async function submit() {
    if(lock.current) return;
    lock.current=true;setBusy(true);setError("");setMessage("");
    try {
      if(raceId && pending) {
        await rpc("review_race_access_as",{p_race:raceId,p_user:pending.item.user_id,p_requested_at:pending.item.requested_at,p_approve:pending.approve,p_role:pending.role});
        setPending(null);setMessage(pending.approve ? `${pending.role === "editor" ? "Editor" : "Viewer"} access approved.` : "Request declined.");
        lock.current=false;await load();onApproved?.();
      }
    } catch {setError("Decision not confirmed. Refresh requests and check the team before retrying.");setPending(null);if(raceId)setItems([]);}
    finally {lock.current=false;setBusy(false);}
  }
  return <section className="grid gap-3 rounded-lg border border-border p-4" aria-label="Race access requests">
    <h3 className="font-semibold">{raceId ? "Access requests" : "Join a race"}</h3>
    {raceId ? <>
      <p className="text-sm text-muted-foreground">Review requests from verified accounts and choose their race access.</p>
      {pending ? <div className="grid gap-2"><p className="break-all">{pending.approve ? `Approve ${pending.role} access for` : "Decline the request from"} {pending.item.email}?</p>
        {pending.approve && <label className="grid gap-1">Access role<select className="min-h-11 rounded border bg-background px-3" value={pending.role} onChange={e=>setPending({...pending,role:e.target.value as "viewer"|"editor"})}><option value="viewer">Viewer</option><option value="editor">Editor</option></select></label>}
        <p className="text-sm">Editors can manage patients. Viewers can see this race’s status board but cannot edit patients or settings.</p>
        <div className="flex gap-2"><button className={button} disabled={busy} onClick={()=>void submit()}>Confirm decision</button><button className={button} disabled={busy} onClick={()=>setPending(null)}>Back</button></div></div>
        : items.map(item=><div key={item.user_id} className="flex flex-wrap items-center gap-2"><span className="min-w-0 flex-1 break-all">{item.email}</span><button className={button} disabled={busy} onClick={()=>setPending({item,approve:true,role:"viewer"})}>Review request</button><button className={button} disabled={busy} onClick={()=>setPending({item,approve:false,role:"viewer"})}>Decline</button></div>)}
      {!busy && !error && items.length===0 && <p className="text-sm">No pending access requests.</p>}
      <button className={button} disabled={busy} onClick={()=>void load()}>Refresh requests</button>
    </> : null}
    {message && <p role="status">{message}</p>}{error && <p role="alert">{error}</p>}
  </section>;
}
