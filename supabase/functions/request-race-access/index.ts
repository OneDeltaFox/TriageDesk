import {createClient} from "npm:@supabase/supabase-js@2.117.3";
import {createAccessHandler} from "./handler.mjs";
const timedFetch=(input:RequestInfo|URL,init?:RequestInit)=>fetch(input,{...init,signal:AbortSignal.timeout(10000)});
const options={auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false},global:{fetch:timedFetch}};
const url=Deno.env.get("SUPABASE_URL")!;
const service=createClient(url,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,options);
Deno.serve(createAccessHandler({
 appUrl:Deno.env.get("INVITATION_APP_URL") ?? "",
 async authenticate(token:string) {
  if(!token) return null;
  const client=createClient(url,Deno.env.get("SUPABASE_ANON_KEY")!,{...options,global:{fetch:timedFetch,headers:{Authorization:`Bearer ${token}`}}});
  const {data,error}=await client.auth.getUser(token);
  return error || !data.user ? null : {client,userId:data.user.id};
 },
 async requestAccess(actor:any,raceId:string) {const {error}=await actor.client.rpc("request_race_access",{p_race:raceId});if(error) throw error;},
 async claim(actor:any,raceId:string) {const {data,error}=await service.rpc("claim_access_request_notification",{p_race:raceId,p_user:actor.userId});if(error) throw error;return data;},
 async send(notice:any,text:string) {
  const key=Deno.env.get("RESEND_API_KEY");if(!key) throw Error("Not configured");
  const results=await Promise.allSettled(notice.recipients.map(async(recipient:{id:string;email:string})=>{
   const response=await timedFetch("https://api.resend.com/emails",{method:"POST",headers:{Authorization:`Bearer ${key}`,"Content-Type":"application/json","Idempotency-Key":`race-access/${notice.id}/${recipient.id}`},body:JSON.stringify({from:"TriageDesk <noreply@triagedeskapp.com>",to:recipient.email,subject:"TriageDesk race access request",text})});
   if(!response.ok || !(await response.json()).id) throw Error("Delivery not confirmed");
  }));
  if(results.some(result=>result.status==='rejected')) throw Error("Delivery not confirmed");
 }
}));
