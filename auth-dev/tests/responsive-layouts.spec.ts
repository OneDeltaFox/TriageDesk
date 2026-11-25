import {expect,test} from '@playwright/test';
for (const [name,width,height] of [['phone',390,844],['phone-landscape',844,390],['tablet',820,1180],['tablet-landscape',1180,820],['desktop',1600,1000]] as const) {
 test(`responsive working board and patient forms: ${name}`,async({page})=>{
  await page.setViewportSize({width,height});
  await page.addInitScript(()=>localStorage.setItem('tent-flow-dev-auth',JSON.stringify({access_token:'token',refresh_token:'refresh',token_type:'bearer',expires_at:Math.floor(Date.now()/1000)+3600,user:{id:'owner'}})));
  const pods=Array.from({length:12},(_,i)=>({id:`pod-${i}`,name:`Pod ${i+1}`,kind:'regular',color:i<6?'#f97316':'#eab308',closed:false,capabilities:[],beds:Array.from({length:4},(_,j)=>({id:`bed-${i}-${j}`,label:`${i+1}-${j+1}`,status:'open'}))}));
  await page.route('**/rest/v1/rpc/my_races',r=>r.fulfill({json:[{id:'race',name:'Race Day Preview',role:'owner',state:'active'}]}));
  await page.route('**/rest/v1/rpc/available_races',r=>r.fulfill({json:[]}));
  await page.route('**/rest/v1/rpc/my_race_invitations',r=>r.fulfill({json:[]}));
  await page.route('**/rest/v1/rpc/race_complaints',r=>r.fulfill({json:[{label:'Dizziness',enabled:true}]}));
  await page.route('**/rest/v1/rpc/patient_board',r=>r.fulfill({json:{pods,visits:[{id:'patient',bib:'1234',triage:'untriaged',complaint:'Dizziness',revision:1,planned_pod_id:'pod-0',medical_started_at:null,dispositioned_at:null}],placements:[],turnovers:[]}}));
  await page.goto('/');await page.getByRole('button',{name:'Open board'}).click();
  const incoming=await page.locator('.working-incoming').boundingBox();const grid=await page.locator('.pod-grid').boundingBox();
  if(width<1024) expect(incoming!.y).toBeLessThan(grid!.y);else expect(incoming!.x+incoming!.width).toBeLessThanOrEqual(grid!.x);
  const columns=await page.locator('.pod-grid').evaluate(el=>getComputedStyle(el).gridTemplateColumns.split(' ').length);
  expect(columns).toBe(width<768?2:3);
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
  await page.screenshot({path:`test-results/layout-${name}.png`,fullPage:true});
  await page.getByRole('button',{name:'New Patient',exact:true}).click();
  const modal=page.getByRole('dialog');await expect(modal).toBeVisible();
  const bounds=await modal.boundingBox();expect(bounds!.x).toBeGreaterThanOrEqual(0);expect(bounds!.y).toBeGreaterThanOrEqual(0);expect(bounds!.x+bounds!.width).toBeLessThanOrEqual(width+1);expect(bounds!.y+bounds!.height).toBeLessThanOrEqual(height+1);
  for(const label of ['Cancel','Add','Add & Next']) { const b=await modal.getByRole('button',{name:label,exact:true}).boundingBox();expect(b!.y).toBeGreaterThanOrEqual(0);expect(b!.y+b!.height).toBeLessThanOrEqual(height); }
  await page.screenshot({path:`test-results/intake-${name}.png`,fullPage:false});
  await modal.getByRole('button',{name:'Cancel',exact:true}).click();
  if(width<1024) {
    const edit=page.getByRole('button',{name:'Edit patient 1234',exact:true});
    if(!await edit.isVisible()) await page.getByRole('button',{name:/Incoming \(1\)/}).click();
  }
  await page.getByRole('button',{name:'Edit patient 1234',exact:true}).click();
  await expect(modal.getByRole('heading',{name:'Edit Patient'})).toBeVisible();
  const save=await modal.getByRole('button',{name:'Save',exact:true}).boundingBox();
  expect(save!.y+save!.height).toBeLessThanOrEqual(height);
  expect(await modal.evaluate(el=>el.scrollWidth<=el.clientWidth)).toBe(true);
 });
}
