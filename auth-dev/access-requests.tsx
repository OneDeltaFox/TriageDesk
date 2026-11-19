import { useEffect, useRef, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";

type Request = { user_id: string; email: string; requested_at: string };
export function AccessRequests({client,raceId,onApproved}: {client:SupabaseClient;raceId?:string;onApproved?:()=>void}) {
  const [code,setCode]=useState("");
  const [items,setItems]=useState<Request[]>([]);
  const [busy,setBusy]=useState(false);
  const [message,setMessage]=useState("");
  const [error,setError]=useState("");
  const [pending,setPending]=useState<{item:Request;approve:boolean}|null>(null);
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
        await rpc("review_race_access",{p_race:raceId,p_user:pending.item.user_id,p_requested_at:pending.item.requested_at,p_approve:pending.approve});
        setPending(null);setMessage(pending.approve ? "Viewer access approved." : "Request declined.");
        lock.current=false;await load();onApproved?.();
      } else if(!raceId) {
        await rpc("request_race_access",{p_race:code.trim()});
        setMessage("Request submitted. An owner must approve access. Use Refresh races after approval.");
      }
    } catch {setError(raceId ? "Decision not confirmed. Refresh requests and check the team before retrying." : "Unable to request access. Verify your email and check the race code with the owner.");setPending(null);if(raceId)setItems([]);}
    finally {lock.current=false;setBusy(false);}
  }
  return <section className="grid gap-3 rounded-lg border border-border p-4" aria-label="Race access requests">
    <h3 className="font-semibold">{raceId ? "Access requests" : "Join a race"}</h3>
    {raceId ? <>
      <label className="grid gap-1 text-sm">Race access code<input readOnly value={raceId} onFocus={event=>event.target.select()} className="min-h-11 w-full rounded border bg-background px-2 font-mono text-xs" /></label>
      <p className="text-sm text-muted-foreground">Share this code with your team. Verified accounts can request access; you approve each person as Viewer.</p>
      {pending ? <div className="grid gap-2"><p className="break-all">{pending.approve ? "Approve Viewer access for" : "Decline the request from"} {pending.item.email}?</p>
        <p className="text-sm">Viewers can see this race’s status board but cannot edit patients or settings.</p>
        <div className="flex gap-2"><button className={button} disabled={busy} onClick={()=>void submit()}>Confirm decision</button><button className={button} disabled={busy} onClick={()=>setPending(null)}>Back</button></div></div>
        : items.map(item=><div key={item.user_id} className="flex flex-wrap items-center gap-2"><span className="min-w-0 flex-1 break-all">{item.email}</span><button className={button} disabled={busy} onClick={()=>setPending({item,approve:true})}>Approve Viewer</button><button className={button} disabled={busy} onClick={()=>setPending({item,approve:false})}>Decline</button></div>)}
      {!busy && !error && items.length===0 && <p className="text-sm">No pending access requests.</p>}
      <button className={button} disabled={busy} onClick={()=>void load()}>Refresh requests</button>
    </> : <form className="grid gap-3" onSubmit={event=>{event.preventDefault();void submit();}}>
      <p className="text-sm text-muted-foreground">Ask the race owner for an access code. Creating an account does not automatically grant race access.</p>
      <label className="grid gap-1">Race access code<input required pattern="[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}" value={code} disabled={busy} onChange={event=>setCode(event.target.value)} className="min-h-11 w-full rounded border bg-background px-3" /></label>
      <button className={button} disabled={busy}>Request Viewer access</button>
    </form>}
    {message && <p role="status">{message}</p>}{error && <p role="alert">{error}</p>}
  </section>;
}
