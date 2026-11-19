const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function createAccessHandler({appUrl,authenticate,requestAccess,claim,send}) {
  let origin; try {const url=new URL(appUrl);if(url.protocol==='https:') origin=url.origin;} catch {}
  return async request=>{
    const headers={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin'};
    if(origin && request.headers.get('Origin')===origin) Object.assign(headers,{'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS'});
    const reply=(status,body)=>new Response(JSON.stringify(body),{status,headers});
    if(!origin) return reply(503,{error:'Not configured'});
    if(request.headers.get('Origin') && request.headers.get('Origin')!==origin) return reply(403,{error:'Origin not allowed'});
    if(request.method==='OPTIONS') return new Response(null,{status:204,headers});
    if(request.method!=='POST') return reply(405,{error:'POST required'});
    let actor,body;
    try {actor=await authenticate(request.headers.get('Authorization')?.match(/^Bearer (.+)$/i)?.[1]);} catch {}
    if(!actor) return reply(401,{error:'Sign in required'});
    try {const raw=await request.text();if(raw.length>256) throw Error();body=JSON.parse(raw);if(!uuid.test(body.raceId) || Object.keys(body).length!==1) throw Error();} catch {return reply(400,{error:'Invalid request'});}
    try {await requestAccess(actor,body.raceId);} catch {return reply(409,{error:'Unable to request access. Verify your email and refresh races.'});}
    try {
      const notice=await claim(actor,body.raceId);
      if(notice) {
        const review=new URL(appUrl);review.searchParams.set('review',body.raceId);
        const text=`${notice.requester} requested access to ${notice.race}.\n\nReview request: ${review.href}\n\nSign in as this race's Owner or Admin to approve Viewer or Editor access. No access is granted by this email.`;
        await send(notice,text);
      }
      return reply(200,{requested:true,notification:notice?'sent':'already_processed'});
    } catch {return reply(200,{requested:true,notification:'unconfirmed'});}
  };
}
