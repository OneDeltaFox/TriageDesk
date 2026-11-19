import {test,expect} from '@playwright/test';
const invitation='00000000-0000-0000-0000-000000000001';
test.beforeEach(async({page})=>{
 await page.addInitScript(()=>localStorage.setItem('tent-flow-dev-auth',JSON.stringify({access_token:'token',refresh_token:'refresh',token_type:'bearer',expires_at:Math.floor(Date.now()/1000)+3600,user:{id:'new',email:'invited@example.test',email_confirmed_at:'2026-11-19'}})));
 await page.route('**/rest/v1/rpc/my_races',r=>r.fulfill({json:[]}));
 await page.route('**/rest/v1/rpc/my_race_invitations',r=>r.fulfill({json:[]}));
 await page.route('**/rest/v1/rpc/available_races',r=>r.fulfill({json:[]}));
});
test('invitation setup locks email, validates password, and accepts after saving',async({page})=>{
 await page.route('**/rest/v1/rpc/my_race_invitations',r=>r.fulfill({json:[{id:invitation,name:'Weekend race',role:'admin'}]}));
 let passwords=0,accepts=0;
 await page.route('**/auth/v1/user',r=>{passwords++;expect(r.request().postDataJSON()).toMatchObject({password:'new-long-password'});return r.fulfill({json:{id:'new',email:'invited@example.test'}});});
 await page.route('**/rest/v1/rpc/accept_race_invitation',r=>{expect(passwords).toBe(1);accepts++;return r.fulfill({status:204});});
 await page.goto('/?setup=invite&invitation='+invitation);
 await expect(page.getByRole('heading',{name:'Set up your account'})).toBeVisible();
 await expect(page.getByLabel('Email / username')).toHaveValue('invited@example.test');await expect(page.getByLabel('Email / username')).toHaveAttribute('readonly','');
 await expect(page.getByRole('heading',{name:'Choose your race'})).toHaveCount(0);
 await page.getByLabel('Password',{exact:true}).fill('new-long-password');await page.getByLabel('Confirm password').fill('different-password');
 await page.getByRole('button',{name:'Create account and accept invitation'}).click();await expect(page.getByRole('alert')).toHaveText('Passwords do not match.');expect(passwords).toBe(0);
 await page.getByLabel('Confirm password').fill('new-long-password');await page.getByRole('button',{name:'Create account and accept invitation'}).click();
 await expect(page.getByRole('heading',{name:'Choose your race'})).toBeVisible();expect(accepts).toBe(1);
});
test('race directory requests access without exposing a board or code entry',async({page})=>{
 let requested=false;
 await page.route('**/rest/v1/rpc/available_races',r=>r.fulfill({json:[{id:'race',name:'Weekend race',state:'active',role:null,requested}]}));
 await page.route('**/functions/v1/request-race-access',r=>{expect(r.request().postDataJSON()).toEqual({raceId:'race'});requested=true;return r.fulfill({json:{requested:true,notification:'sent'}});});
 await page.goto('/');await expect(page.getByText('Weekend race',{exact:true})).toBeVisible();await expect(page.getByRole('button',{name:'Open board'})).toHaveCount(0);await expect(page.getByLabel('Race access code')).toHaveCount(0);
 await page.getByRole('button',{name:'Request access',exact:true}).click();await expect(page.getByText('Awaiting approval',{exact:true})).toBeVisible();await expect(page.getByRole('button',{name:'Request access',exact:true})).toHaveCount(0);
});
