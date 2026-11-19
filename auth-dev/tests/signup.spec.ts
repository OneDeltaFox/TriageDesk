import {test,expect} from "@playwright/test";

test("email signup confirms passwords and requests verification without race access",async({page})=>{
  let signups=0;
  await page.route("**/auth/v1/signup**",async route=>{
    signups++;
    expect(route.request().postDataJSON()).toMatchObject({email:"runner@yahoo.com",password:"long-test-password"});
    expect(route.request().postDataJSON()).not.toHaveProperty("role");
    expect(route.request().url()).toContain("redirect_to=");
    await route.fulfill({json:{id:"new-user",email:"runner@yahoo.com",identities:[]}});
  });
  await page.route("**/rest/v1/rpc/my_races",()=>{throw new Error("Unverified signup must not load races");});
  await page.goto("/");
  await page.getByRole("button",{name:"New here? Create an account"}).click();
  await page.getByLabel("Email",{exact:true}).fill("runner@yahoo.com");
  await page.getByLabel("Password",{exact:true}).fill("long-test-password");
  await page.getByLabel("Confirm password",{exact:true}).fill("different-password");
  await page.setViewportSize({width:390,height:844});
  await page.screenshot({path:"test-results/signup-phone.png",fullPage:true});
  await page.getByRole("button",{name:"Create account",exact:true}).click();
  await expect(page.getByRole("alert")).toHaveText("Passwords do not match.");
  expect(signups).toBe(0);
  await page.getByLabel("Confirm password",{exact:true}).fill("long-test-password");
  await page.getByRole("button",{name:"Create account",exact:true}).click();
  await expect(page.getByRole("heading",{name:"Verify your email"})).toBeVisible();
  await expect(page.getByRole("status")).toContainText("Check your email");
  await expect(page.getByLabel("Password",{exact:true})).toHaveCount(0);
  expect(signups).toBe(1);
});

test("unconfirmed login offers verification resend and delivery errors remain recoverable",async({page})=>{
  await page.route("**/auth/v1/token**",route=>route.fulfill({status:400,json:{error_code:"email_not_confirmed",msg:"Email not confirmed"}}));
  await page.route("**/auth/v1/resend**",route=>{
    expect(route.request().postDataJSON()).toMatchObject({type:"signup",email:"runner@example.com"});
    return route.fulfill({status:429,json:{msg:"Rate limited"}});
  });
  await page.goto("/");
  await page.getByLabel("Email",{exact:true}).fill("runner@example.com");
  await page.getByLabel("Password",{exact:true}).fill("long-test-password");
  await page.getByRole("button",{name:"Sign in",exact:true}).click();
  await expect(page.getByRole("heading",{name:"Verify your email"})).toBeVisible();
  await page.getByRole("button",{name:"Resend verification email"}).click();
  await expect(page.getByRole("alert")).toContainText("Unable to send verification email");
  await expect(page.getByRole("button",{name:"Resend verification email"})).toBeEnabled();
});

test("verified account can request race access but cannot open a board until approved",async({page})=>{
  await page.addInitScript(()=>localStorage.setItem("tent-flow-dev-auth",JSON.stringify({access_token:"token",refresh_token:"refresh",token_type:"bearer",expires_at:Math.floor(Date.now()/1000)+3600,user:{id:"new-user",email:"runner@example.com",email_confirmed_at:"2026-11-18T00:00:00Z"}})));
  await page.route("**/rest/v1/rpc/my_races",r=>r.fulfill({json:[]}));
  await page.route("**/rest/v1/rpc/my_race_invitations",r=>r.fulfill({json:[]}));
  await page.route("**/rest/v1/rpc/request_race_access_by_code",r=>{
    expect(r.request().postDataJSON()).toEqual({p_code:"WINE5K"});
    return r.fulfill({status:204});
  });
  await page.goto("/");
  await page.getByLabel("Race access code",{exact:true}).fill("wine5k");
  await page.getByRole("button",{name:"Request Viewer access"}).click();
  await expect(page.getByText(/Request submitted/)).toBeVisible();
  await expect(page.getByRole("button",{name:"Open board"})).toHaveCount(0);
});

test("owner reviews a verified request before granting Viewer access",async({page})=>{
  await page.addInitScript(()=>localStorage.setItem("tent-flow-dev-auth",JSON.stringify({access_token:"token",refresh_token:"refresh",token_type:"bearer",expires_at:Math.floor(Date.now()/1000)+3600,user:{id:"owner"}})));
  await page.route("**/rest/v1/rpc/my_races",r=>r.fulfill({json:[{id:"race",name:"Test",role:"owner",state:"active"}]}));
  await page.route("**/rest/v1/rpc/patient_board",r=>r.fulfill({json:{pods:[],visits:[],placements:[],turnovers:[]}}));
  await page.route("**/rest/v1/rpc/race_team",r=>r.fulfill({json:[]}));
  await page.route("**/rest/v1/rpc/race_invitations",r=>r.fulfill({json:[]}));
  let requests=[{user_id:"new-user",email:"runner@example.com",requested_at:"2026-11-18T00:00:00Z"}];let decisions=0;
  await page.route("**/rest/v1/rpc/race_access_requests",r=>r.fulfill({json:requests}));
  await page.route("**/rest/v1/rpc/review_race_access",r=>{
    decisions++;expect(r.request().postDataJSON()).toEqual({p_race:"race",p_user:"new-user",p_requested_at:"2026-11-18T00:00:00Z",p_approve:true});requests=[];return r.fulfill({status:204});
  });
  await page.goto("/");await page.getByRole("button",{name:"Open board"}).click();
  await page.getByRole("button",{name:"Menu",exact:true}).click();await page.getByRole("button",{name:"Manage Team",exact:true}).click();
  await page.getByRole("button",{name:"Approve Viewer"}).click();expect(decisions).toBe(0);
  await page.getByRole("button",{name:"Confirm decision"}).click();
  await expect(page.getByText("No pending access requests.")).toBeVisible();expect(decisions).toBe(1);
});

test.beforeEach(async({page})=>{await page.route("**/rest/v1/rpc/race_access_code",r=>r.fulfill({json:"WINE5K"}));});

test('owner saves a custom code and sees the saved value',async({page})=>{
 await page.addInitScript(()=>localStorage.setItem('tent-flow-dev-auth',JSON.stringify({access_token:'token',refresh_token:'refresh',token_type:'bearer',expires_at:Math.floor(Date.now()/1000)+3600,user:{id:'owner'}})));
 for(const endpoint of ['race_team','race_invitations','my_race_invitations','race_access_requests']) await page.route('**/rest/v1/rpc/'+endpoint,r=>r.fulfill({json:[]}));
 await page.route('**/rest/v1/rpc/my_races',r=>r.fulfill({json:[{id:'race',name:'Test',role:'owner',state:'active'}]}));
 await page.route('**/rest/v1/rpc/patient_board',r=>r.fulfill({json:{pods:[],visits:[],placements:[],turnovers:[]}}));
 await page.route('**/rest/v1/rpc/set_race_access_code',r=>{expect(r.request().postDataJSON()).toEqual({p_race:'race',p_expected:'WINE5K',p_code:'RACE2026'});return r.fulfill({json:'RACE2026'});});
 await page.goto('/');await page.getByRole('button',{name:'Open board'}).click();await page.getByRole('button',{name:'Menu',exact:true}).click();await page.getByRole('button',{name:'Manage Team',exact:true}).click();
 await expect(page.getByLabel('Race access code',{exact:true})).toHaveValue('WINE5K');await page.getByLabel('Race access code',{exact:true}).fill('race2026');await page.getByRole('button',{name:'Save access code'}).click();await expect(page.getByText('Access code saved. Share it with your team.')).toBeVisible();await expect(page.getByLabel('Race access code',{exact:true})).toHaveValue('RACE2026');
});
