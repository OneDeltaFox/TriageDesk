import { useEffect, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";

export function AccessCode({client,raceId,isOwner}:{client:SupabaseClient;raceId:string;isOwner:boolean}) {
  const [saved,setSaved]=useState<string|null>(null);
  const [draft,setDraft]=useState("");
  const [ready,setReady]=useState(false);
  const [busy,setBusy]=useState(false);
  const [message,setMessage]=useState("");
  const [error,setError]=useState("");
  async function load() {
    setBusy(true);setReady(false);setError("");
    try {
      const result=await client.rpc("race_access_code",{p_race:raceId}).abortSignal(AbortSignal.timeout(15000));
      if(result.error) throw result.error;
      setSaved(result.data);setDraft(result.data ?? "");setReady(true);
    } catch {setError("Unable to load the access code. Refresh and try again.");}
    finally {setBusy(false);}
  }
  useEffect(()=>{void load();},[client,raceId]);
  async function save() {
    setBusy(true);setError("");setMessage("");
    try {
      const result=await client.rpc("set_race_access_code",{p_race:raceId,p_expected:saved,p_code:draft.trim().toUpperCase()}).abortSignal(AbortSignal.timeout(15000));
      if(result.error) throw result.error;
      setSaved(result.data);setDraft(result.data);setMessage("Access code saved. Share it with your team.");
    } catch {setReady(false);setError("Code not saved or not confirmed. It may already be in use or have changed. Refresh the code before retrying.");}
    finally {setBusy(false);}
  }
  return <form className="grid gap-2" onSubmit={e=>{e.preventDefault();void save();}}>
    <label className="grid gap-1 text-sm">Race access code<input value={draft} readOnly={!isOwner} disabled={busy || !ready} required minLength={4} maxLength={24} pattern="[A-Za-z0-9][A-Za-z0-9-]{3,23}" autoCapitalize="characters" autoCorrect="off" spellCheck={false} placeholder={isOwner ? "e.g. WINE5K" : "Owner has not set a code"} onChange={e=>setDraft(e.target.value.toUpperCase())} className="min-h-11 w-full rounded border bg-background px-3 font-mono" /></label>
    <p className="text-sm text-muted-foreground">{isOwner ? "Choose 4–24 letters, numbers or hyphens. Changing the code leaves existing team access and pending requests unchanged." : "Share this code with your team. Ask the Owner to change it."}</p>
    <div className="flex flex-wrap gap-2">{isOwner && <button disabled={busy || !ready || draft.trim().toUpperCase()===saved} className="min-h-11 rounded border px-3 disabled:opacity-50">Save access code</button>}<button type="button" disabled={busy} onClick={()=>void load()} className="min-h-11 rounded border px-3">Refresh code</button></div>
    {message && <p role="status">{message}</p>}{error && <p role="alert">{error}</p>}
  </form>;
}
