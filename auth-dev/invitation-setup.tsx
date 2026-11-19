import {useEffect,useRef,useState} from "react";
import type {SupabaseClient,Session} from "@supabase/supabase-js";

export function InvitationSetup({client,session,invitationId,onDone}:{client:SupabaseClient;session:Session;invitationId:string;onDone:()=>void}) {
 const [invite,setInvite]=useState<{id:string;name:string;role:string}|null>(null);
 const [password,setPassword]=useState("");const [confirmation,setConfirmation]=useState("");
 const [busy,setBusy]=useState(false);const [saved,setSaved]=useState(false);const [error,setError]=useState("");const lock=useRef(false);
 useEffect(()=>{let active=true;client.rpc('my_race_invitations').then(({data,error})=>{if(!active)return;const match=data?.find((i:{id:string})=>i.id===invitationId);if(error || !match)setError('Invitation unavailable. It may have expired or already been accepted.');else setInvite(match);});return()=>{active=false;};},[client,invitationId]);
 async function submit(e:React.FormEvent) {
  e.preventDefault();if(lock.current || !invite)return;setError('');
  if(!saved && password!==confirmation){setError('Passwords do not match.');return;}
  lock.current=true;setBusy(true);
  try {
   if(!saved){const result=await client.auth.updateUser({password});if(result.error)throw Error('Unable to save your password. Try again or request a new invitation link.');setSaved(true);setPassword('');setConfirmation('');}
   const result=await client.rpc('accept_race_invitation',{p_invitation:invite.id});
   if(result.error)throw Error('Your password was saved, but race access was not confirmed. Continue to races to check, or retry acceptance.');
   onDone();
  }catch(e){setError(e instanceof Error?e.message:'Unable to connect. Try again.');}finally{lock.current=false;setBusy(false);}
 }
 return <form onSubmit={submit} className="mx-auto grid w-full max-w-md gap-4 rounded-lg border p-6">
  <h2 className="text-2xl font-semibold">Set up your account</h2>
  <label className="grid gap-2">Email / username<input readOnly value={session.user.email ?? ''} className="min-h-12 rounded border bg-background px-3" /></label>
  {invite && <p>Accept <strong className="capitalize">{invite.role}</strong> access to {invite.name}.</p>}
  {!saved && <><label className="grid gap-2">Password<input type="password" autoComplete="new-password" minLength={12} required value={password} disabled={busy} onChange={e=>setPassword(e.target.value)} className="min-h-12 rounded border bg-background px-3" /></label><label className="grid gap-2">Confirm password<input type="password" autoComplete="new-password" minLength={12} required value={confirmation} disabled={busy} onChange={e=>setConfirmation(e.target.value)} className="min-h-12 rounded border bg-background px-3" /></label><p className="text-sm">Use at least 12 characters. Your email address is your username.</p></>}
  <button disabled={busy || !invite} className="desk-primary">{saved?'Accept invitation':'Create account and accept invitation'}</button>
  {error && <><p role="alert">{error}</p><button type="button" className="desk-secondary" disabled={busy} onClick={onDone}>Continue to races</button></>}
 </form>;
}
