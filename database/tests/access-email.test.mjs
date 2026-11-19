import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createAccessHandler} from '../../supabase/functions/request-race-access/handler.mjs';
test('access emails authenticate, use server recipients and preserve requests on delivery failure',async()=>{
 let requests=0,sends=0,claimed=false;
 const options={appUrl:'https://triagedeskapp.com/',authenticate:async token=>token==='valid'?{}:null,
 requestAccess:async()=>{requests++;},claim:async()=>{if(claimed)return null;claimed=true;return {id:'notice',requester:'user@example.test',race:'Test Race',recipients:[{id:'owner',email:'owner@example.test'}]};},
 send:async(notice,text)=>{sends++;assert.match(text,/Review request: https:\/\/triagedeskapp.com\/\?review=/);assert.equal(notice.recipients[0].email,'owner@example.test');}};
 const handler=createAccessHandler(options),raceId='00000000-0000-0000-0000-000000000001';
 const req=(body={raceId},token='valid',origin='https://triagedeskapp.com')=>new Request('https://example.test',{method:'POST',headers:{Authorization:`Bearer ${token}`,Origin:origin},body:JSON.stringify(body)});
 assert.equal((await handler(req({raceId},'bad'))).status,401);
 assert.equal((await handler(req({raceId},'valid','https://evil.test'))).status,403);
 assert.equal((await handler(req({raceId,recipients:['evil@test']}))).status,400);
 assert.equal(requests,0);
 assert.equal((await (await handler(req())).json()).notification,'sent');
 assert.equal((await (await handler(req())).json()).notification,'already_processed');assert.equal(sends,1);
 const failed=createAccessHandler({...options,claim:async()=>({}),send:async()=>{throw Error();}});
 assert.deepEqual(await (await failed(req())).json(),{requested:true,notification:'unconfirmed'});
});

import {invitationRedirects} from '../../supabase/functions/send-race-invitation/handler.mjs';
test('new invitation links open setup while existing accounts keep ordinary sign-in',()=>{
 const urls=invitationRedirects('https://triagedeskapp.com/','invite-id');
 assert.equal(new URL(urls.newAccount).searchParams.get('setup'),'invite');
 assert.equal(new URL(urls.newAccount).searchParams.get('invitation'),'invite-id');
 assert.equal(urls.existingAccount,'https://triagedeskapp.com/');
});
